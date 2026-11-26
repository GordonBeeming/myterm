use crate::session::{check, Session, Shell};
use crate::socket::{PeerEvents, Socket};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

const MAX_FRAME: usize = 65_536;
const MAX_QUEUE: usize = 256 * 1024;
const READ_SIZE: usize = 16 * 1024;
const HEADER_SIZE: usize = 5;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const START: u8 = 1;
const ATTACH: u8 = 2;
const INPUT: u8 = 3;
const RESIZE: u8 = 4;
const READY: u8 = 0x81;
const OUTPUT: u8 = 0x82;
const END: u8 = 0x83;

pub struct Server<Authenticate> {
    socket: Socket,
    authenticate: Authenticate,
    shell: Shell,
    session: Option<Session>,
    connection: Option<Connection>,
}

impl<Authenticate: Fn(&UnixStream) -> io::Result<()>> Server<Authenticate> {
    pub fn bind(path: &Path, authenticate: Authenticate, shell: Shell) -> io::Result<Self> {
        Ok(Self {
            socket: Socket::bind(path)?,
            authenticate,
            shell,
            session: None,
            connection: None,
        })
    }

    pub fn run(&mut self, stopping: impl Fn() -> bool) -> io::Result<()> {
        while !stopping() {
            let wait = if self.connection.is_none() && self.session.is_none() {
                // Bound the missed wakeup if a signal arrives just before poll.
                1_000
            } else {
                100
            };
            self.step(wait)?;
        }
        Ok(())
    }

    pub fn step(&mut self, wait: libc::c_int) -> io::Result<()> {
        let mut descriptors = [
            poll_descriptor(self.socket.listener.as_raw_fd(), libc::POLLIN),
            self.connection.as_ref().map_or(inactive_poll(), |client| {
                let mut events = 0;
                if client.closing.is_none() && !client.input_blocked {
                    events |= libc::POLLIN;
                }
                if !client.outgoing.is_empty() {
                    events |= libc::POLLOUT;
                }
                poll_descriptor(client.stream.as_raw_fd(), events)
            }),
            self.session.as_ref().map_or(inactive_poll(), |session| {
                let mut events = 0;
                if self.output_capacity() > 0 {
                    events |= libc::POLLIN;
                }
                if self
                    .connection
                    .as_ref()
                    .is_some_and(|client| !client.pending_input.is_empty())
                {
                    events |= libc::POLLOUT;
                }
                if events == 0 {
                    return inactive_poll();
                }
                poll_descriptor(session.master.as_raw_fd(), events)
            }),
        ];
        let result = check(unsafe {
            libc::poll(
                descriptors.as_mut_ptr(),
                descriptors.len() as libc::nfds_t,
                wait,
            )
        });
        if let Err(error) = result {
            if error.kind() == io::ErrorKind::Interrupted {
                return Ok(());
            }
            return Err(error);
        }

        if let Some(mut client) = self.connection.take() {
            match self.update_connection(&mut client, descriptors[1].revents) {
                Ok(true) => self.connection = Some(client),
                Ok(false) => {}
                Err(error) => eprintln!("Local terminal client disconnected: {error}"),
            }
        }
        if let Some(mut session) = self.session.take() {
            match self.update_session(&mut session, descriptors[2].revents) {
                Ok(true) => self.session = Some(session),
                Ok(false) => {}
                Err(error) => {
                    self.finish_session(&format!("Terminal session failed: {error}"));
                    if let Err(cleanup_error) = session.stop() {
                        eprintln!("Could not stop failed terminal session: {cleanup_error}");
                    }
                }
            }
        }
        if descriptors[0].revents & libc::POLLIN != 0 {
            self.accept()?;
        }
        if descriptors[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return Err(io::Error::other("Local terminal listener failed"));
        }
        Ok(())
    }

    fn accept(&mut self) -> io::Result<()> {
        let (stream, _) = match self.socket.listener.accept() {
            Ok(pair) => pair,
            Err(error) if retryable(&error) || error.kind() == io::ErrorKind::ConnectionAborted => {
                return Ok(())
            }
            Err(error) => return Err(error),
        };
        stream.set_nonblocking(true)?;
        if let Err(error) = (self.authenticate)(&stream) {
            eprintln!("Rejected local terminal peer: {error}");
            send_rejection(stream, "Untrusted local terminal client");
            return Ok(());
        }
        if self.connection.is_some() {
            send_rejection(stream, "A local terminal client is already connected");
            return Ok(());
        }
        self.connection = Some(Connection::new(stream)?);
        Ok(())
    }

    fn update_connection(&mut self, client: &mut Connection, events: i16) -> io::Result<bool> {
        if events & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
            || (client.input_blocked && client.peer_events.closed()?)
        {
            return Ok(false);
        }
        if client.closing.is_none() {
            self.parse_messages(client);
            if !client.input_blocked && client.closing.is_none() && events & libc::POLLIN != 0 {
                let mut bytes = [0; READ_SIZE];
                match client.stream.read(&mut bytes) {
                    Ok(0) => return Ok(false),
                    Ok(count) => client.incoming.extend_from_slice(&bytes[..count]),
                    Err(error) if retryable(&error) => {}
                    Err(error) => return Err(error),
                }
                self.parse_messages(client);
            }
        }

        flush(&mut client.outgoing, &mut client.stream)?;
        if let Some(closing) = &client.closing {
            let expired =
                matches!(closing, Closing::Rejecting(deadline) if Instant::now() >= *deadline);
            return Ok(!client.outgoing.is_empty() && !expired);
        }
        Ok(client.attached || Instant::now() < client.handshake_deadline)
    }

    fn parse_messages(&mut self, client: &mut Connection) {
        let mut consumed = 0;
        client.input_blocked = false;
        while let Some(header) = client.incoming[consumed..].first_chunk::<HEADER_SIZE>() {
            let [kind, a, b, c, d] = *header;
            let length = u32::from_be_bytes([a, b, c, d]) as usize;
            if length > MAX_FRAME {
                client.reject("Local terminal frame is too large");
                break;
            }
            // Leave the next input frame in the socket or decoder until the PTY
            // can accept it. A subsequent resize must keep its place in the stream.
            if client.attached && kind == INPUT && length > MAX_QUEUE - client.pending_input.len() {
                client.input_blocked = true;
                break;
            }
            let start = consumed + HEADER_SIZE;
            let end = start + length;
            let Some(payload) = client.incoming.get(start..end) else {
                break;
            };
            let result =
                self.handle_message(&mut client.pending_input, client.attached, kind, payload);
            consumed = end;
            match result {
                Ok(Some(identity)) => {
                    client.attached = true;
                    client.queue(READY, &identity);
                }
                Ok(None) => {}
                Err(error) => {
                    client.reject(&error.to_string());
                    break;
                }
            }
        }
        client.incoming.drain(..consumed);
    }

    fn handle_message(
        &mut self,
        pending_input: &mut VecDeque<u8>,
        attached: bool,
        kind: u8,
        payload: &[u8],
    ) -> io::Result<Option<[u8; 8]>> {
        if !attached {
            let id: [u8; 16] = payload.try_into().map_err(|_| {
                io::Error::other("A 16-byte terminal session identifier is required")
            })?;
            match kind {
                START if self.session.is_some() => {
                    return Err(io::Error::other("A terminal session is already running"));
                }
                START => {
                    let session = self.shell.start(id).map_err(|error| {
                        io::Error::other(format!("Could not start terminal shell: {error}"))
                    })?;
                    self.session = Some(session);
                }
                ATTACH
                    if self
                        .session
                        .as_ref()
                        .is_some_and(|session| session.id == id) => {}
                ATTACH => {
                    return Err(io::Error::other(
                        "No live terminal session matches this identifier",
                    ))
                }
                _ => {
                    return Err(io::Error::other(
                        "Start or attach to a terminal session first",
                    ))
                }
            }
            let session = self
                .session
                .as_ref()
                .ok_or_else(|| io::Error::other("Terminal session is unavailable"))?;
            let mut identity = [0; 8];
            identity[..4].copy_from_slice(&std::process::id().to_be_bytes());
            identity[4..].copy_from_slice(&session.child.id().to_be_bytes());
            return Ok(Some(identity));
        }
        let session = self
            .session
            .as_ref()
            .ok_or_else(|| io::Error::other("Terminal session is unavailable"))?;
        match (kind, payload) {
            (INPUT, _) => pending_input.extend(payload),
            (RESIZE, [a, b, c, d]) => {
                session.resize(u16::from_be_bytes([*a, *b]), u16::from_be_bytes([*c, *d]))?;
            }
            _ => return Err(io::Error::other("Invalid terminal message")),
        }
        Ok(None)
    }

    fn update_session(&mut self, session: &mut Session, events: i16) -> io::Result<bool> {
        let status = session.child.try_wait()?;
        if events & libc::POLLNVAL != 0 {
            return Err(io::Error::other("Terminal PTY descriptor is unavailable"));
        }
        if events & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 || status.is_some() {
            let drained = self.read_output(session)?;
            if let Some(status) = status.filter(|_| drained) {
                self.finish_session(&format!("Terminal shell ended ({status})"));
                return Ok(false);
            }
        }
        if status.is_none() && events & libc::POLLOUT != 0 && events & libc::POLLHUP == 0 {
            if let Some(client) = &mut self.connection {
                flush(&mut client.pending_input, &mut session.master)?;
            }
        }
        Ok(true)
    }

    fn read_output(&mut self, session: &mut Session) -> io::Result<bool> {
        let mut bytes = [0; READ_SIZE];
        for _ in 0..4 {
            let capacity = self.output_capacity();
            if capacity == 0 {
                return Ok(false);
            }
            match session.master.read(&mut bytes[..capacity]) {
                Ok(0) => return Ok(true),
                Ok(count) => {
                    if let Some(client) = self.attached_client_mut() {
                        client.queue(OUTPUT, &bytes[..count]);
                    }
                }
                // Some Unix PTYs report EIO when the last slave descriptor closes.
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.raw_os_error() == Some(libc::EIO) =>
                {
                    return Ok(true)
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(false)
    }

    fn output_capacity(&self) -> usize {
        self.connection
            .as_ref()
            .filter(|client| client.attached && client.closing.is_none())
            .map_or(READ_SIZE, |client| {
                READ_SIZE.min(MAX_QUEUE.saturating_sub(client.outgoing.len() + HEADER_SIZE))
            })
    }

    fn attached_client_mut(&mut self) -> Option<&mut Connection> {
        self.connection
            .as_mut()
            .filter(|client| client.attached && client.closing.is_none())
    }

    fn finish_session(&mut self, message: &str) {
        if let Some(client) = self.attached_client_mut() {
            client.end(message, Closing::Finishing);
        }
    }
}

impl<Authenticate> Drop for Server<Authenticate> {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            if let Err(error) = session.stop() {
                eprintln!("Could not stop local terminal session: {error}");
            }
        }
    }
}

struct Connection {
    stream: UnixStream,
    peer_events: PeerEvents,
    incoming: Vec<u8>,
    outgoing: VecDeque<u8>,
    pending_input: VecDeque<u8>,
    input_blocked: bool,
    attached: bool,
    handshake_deadline: Instant,
    closing: Option<Closing>,
}

enum Closing {
    Finishing,
    Rejecting(Instant),
}

impl Connection {
    fn new(stream: UnixStream) -> io::Result<Self> {
        Ok(Self {
            peer_events: PeerEvents::new(&stream)?,
            stream,
            incoming: Vec::new(),
            outgoing: VecDeque::new(),
            pending_input: VecDeque::new(),
            input_blocked: false,
            attached: false,
            handshake_deadline: Instant::now() + HANDSHAKE_TIMEOUT,
            closing: None,
        })
    }

    fn queue(&mut self, kind: u8, bytes: &[u8]) {
        queue_frame(&mut self.outgoing, kind, bytes);
    }

    fn reject(&mut self, message: &str) {
        self.end(
            message,
            Closing::Rejecting(Instant::now() + HANDSHAKE_TIMEOUT),
        );
    }

    fn end(&mut self, message: &str, closing: Closing) {
        if self.closing.is_none() {
            self.pending_input.clear();
            self.queue(END, message.as_bytes());
            self.closing = Some(closing);
        }
    }
}

fn send_rejection(mut stream: UnixStream, message: &str) {
    let mut outgoing = VecDeque::new();
    queue_frame(&mut outgoing, END, message.as_bytes());
    if let Err(error) = flush(&mut outgoing, &mut stream) {
        eprintln!("Could not send local terminal rejection: {error}");
    }
}

fn queue_frame(outgoing: &mut VecDeque<u8>, kind: u8, bytes: &[u8]) {
    outgoing.push_back(kind);
    outgoing.extend((bytes.len() as u32).to_be_bytes());
    outgoing.extend(bytes);
}

fn poll_descriptor(fd: i32, events: i16) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
}

fn inactive_poll() -> libc::pollfd {
    poll_descriptor(-1, 0)
}

fn flush(queue: &mut VecDeque<u8>, writer: &mut impl Write) -> io::Result<()> {
    while !queue.is_empty() {
        match writer.write(queue.as_slices().0) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(count) => {
                queue.drain(..count);
            }
            Err(error) if retryable(&error) => break,
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn retryable(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
    )
}
