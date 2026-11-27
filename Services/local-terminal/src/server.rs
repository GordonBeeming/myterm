use crate::session::{check, LaunchOptions, Session, Shell, StoppingShell};
use crate::socket::{PeerEvents, Socket};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

const MAX_SESSIONS: usize = 64;
const MAX_CONNECTIONS: usize = 128;
const FD_HEADROOM: usize = 32;
const ACCEPT_BACKOFF: Duration = Duration::from_millis(250);
const MAX_USED_IDENTIFIERS: usize = 65_536;
const MAX_FRAME: usize = 65_536;
const MAX_QUEUE: usize = 256 * 1024;
const CONTROL_RESERVE: usize = 512;
const READ_SIZE: usize = 16 * 1024;
const HEADER_SIZE: usize = 5;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const START: u8 = 1;
const ATTACH: u8 = 2;
const INPUT: u8 = 3;
const RESIZE: u8 = 4;
const LAUNCH: u8 = 5;
const VIEW_ATTACH: u8 = 6;
const TAKE_CONTROL: u8 = 7;
const RELEASE_CONTROL: u8 = 8;
const STOP: u8 = 9;
const DETACH: u8 = 10;
const STOP_SESSION: u8 = 14;
const READY: u8 = 0x81;
const OUTPUT: u8 = 0x82;
const END: u8 = 0x83;
const CONTROL: u8 = 0x84;
const CONTROL_REJECTED: u8 = 0x85;
const GEOMETRY: u8 = 0x88;
const GEOMETRY_FRAME_SIZE: usize = HEADER_SIZE + 4;
const CONTROL_FRAME_SIZE: usize = HEADER_SIZE + 25;

type Identifier = [u8; 16];
const NO_OWNER: Identifier = [0; 16];

pub struct Server<Authenticate> {
    socket: Socket,
    authenticate: Authenticate,
    shell: Shell,
    sessions: HashMap<Identifier, ManagedSession>,
    used_identifiers: HashSet<Identifier>,
    connections: BTreeMap<RawFd, Connection>,
    stopping_shells: Vec<StoppingShell>,
    descriptor_budget: usize,
    accept_retry_at: Option<Instant>,
}

impl<Authenticate: Fn(&UnixStream) -> io::Result<()>> Server<Authenticate> {
    pub fn bind(path: &Path, authenticate: Authenticate, shell: Shell) -> io::Result<Self> {
        Ok(Self {
            descriptor_budget: descriptor_budget()?,
            socket: Socket::bind(path)?,
            authenticate,
            shell,
            sessions: HashMap::new(),
            used_identifiers: HashSet::new(),
            connections: BTreeMap::new(),
            stopping_shells: Vec::new(),
            accept_retry_at: None,
        })
    }

    pub fn run(&mut self, stopping: impl Fn() -> bool) -> io::Result<()> {
        while !stopping() {
            let wait = if self.connections.is_empty()
                && self.sessions.is_empty()
                && self.stopping_shells.is_empty()
            {
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
        let (listener, wait) = match self.accept_retry_at {
            Some(retry) if retry > Instant::now() => {
                let delay = retry.saturating_duration_since(Instant::now());
                (-1, wait.min(delay.as_millis() as i32 + 1))
            }
            _ => (self.socket.listener.as_raw_fd(), wait),
        };
        let mut descriptors = vec![poll_descriptor(listener, libc::POLLIN)];
        let connections: Vec<_> = self.connections.keys().copied().collect();
        descriptors.extend(self.connections.values().map(Connection::poll_descriptor));
        let session_offset = descriptors.len();
        let sessions: Vec<_> = self.sessions.keys().copied().collect();
        for id in &sessions {
            let session = &self.sessions[id];
            let mut events = 0;
            if self.output_capacity(*id, session) > 0 {
                events |= libc::POLLIN;
            }
            if !session.pending_input.is_empty() {
                events |= libc::POLLOUT;
            }
            // Darwin can report a hangup repeatedly even when no events are requested.
            let fd = if events == 0 {
                -1
            } else {
                session.pty.master.as_raw_fd()
            };
            descriptors.push(poll_descriptor(fd, events));
        }

        if let Err(error) = check(unsafe {
            libc::poll(
                descriptors.as_mut_ptr(),
                descriptors.len() as libc::nfds_t,
                wait,
            )
        }) {
            if error.kind() == io::ErrorKind::Interrupted {
                return Ok(());
            }
            return Err(error);
        }

        for (fd, descriptor) in connections.into_iter().zip(&descriptors[1..session_offset]) {
            if let Some(mut client) = self.connections.remove(&fd) {
                match self.update_connection(&mut client, descriptor.revents) {
                    Ok(true) => {
                        self.connections.insert(fd, client);
                    }
                    Ok(false) => {}
                    Err(error) => eprintln!("Local terminal client disconnected: {error}"),
                }
            }
        }
        self.publish_control();
        for (id, descriptor) in sessions.into_iter().zip(&descriptors[session_offset..]) {
            if let Some(mut session) = self.sessions.remove(&id) {
                match self.update_session(id, &mut session, descriptor.revents) {
                    Ok(true) => {
                        self.sessions.insert(id, session);
                    }
                    Ok(false) => {}
                    Err(error) => {
                        eprintln!("Local terminal session {id:x?} failed: {error}");
                        self.finish_session(id, "Terminal session failed");
                        self.stopping_shells.push(session.pty.begin_stop());
                    }
                }
            }
        }
        reap_shells(&mut self.stopping_shells);

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
            Err(error) => return self.accept_error(error),
        };
        if let Err(error) = stream.set_nonblocking(true) {
            eprintln!("Could not configure local terminal client socket: {error}");
            return Ok(());
        }
        if let Err(error) = (self.authenticate)(&stream) {
            eprintln!("Rejected local terminal peer: {error}");
            send_rejection(stream, "Untrusted local terminal client");
            return Ok(());
        }
        if !self.can_admit(self.sessions.len(), self.connections.len() + 1) {
            send_rejection(stream, "Local terminal connection limit reached");
            return Ok(());
        }
        let fd = stream.as_raw_fd();
        match Connection::new(stream) {
            Ok(client) => {
                self.accept_retry_at = None;
                self.connections.insert(fd, client);
            }
            Err(error) if descriptor_exhausted(&error) => self.accept_error(error)?,
            Err(error) => eprintln!("Could not initialize local terminal client: {error}"),
        }
        Ok(())
    }

    fn accept_error(&mut self, error: io::Error) -> io::Result<()> {
        if descriptor_exhausted(&error) {
            if self.accept_retry_at.is_none() {
                eprintln!("Local terminal listener is temporarily out of descriptors: {error}");
            }
            self.accept_retry_at = Some(Instant::now() + ACCEPT_BACKOFF);
            return Ok(());
        }
        if retryable(&error) || error.kind() == io::ErrorKind::ConnectionAborted {
            return Ok(());
        }
        Err(error)
    }

    fn can_admit(&self, sessions: usize, connections: usize) -> bool {
        connections <= MAX_CONNECTIONS && sessions + 2 * connections <= self.descriptor_budget
    }

    fn update_connection(&mut self, client: &mut Connection, events: i16) -> io::Result<bool> {
        if events & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
            || (client.input_blocked && client.peer_events.closed()?)
        {
            return Ok(false);
        }
        if client.closing.is_none() {
            if client.handshake_expired() {
                return Ok(false);
            }
            self.parse_messages(client);
            if !client.input_blocked && client.closing.is_none() && events & libc::POLLIN != 0 {
                let mut bytes = [0; READ_SIZE];
                match client.stream.read(&mut bytes) {
                    Ok(0) => return Ok(false),
                    Ok(count) => client.incoming.extend_from_slice(&bytes[..count]),
                    Err(error) if retryable(&error) => {}
                    Err(error) => return Err(error),
                }
                if client.handshake_expired() {
                    return Ok(false);
                }
                self.parse_messages(client);
            }
        }

        flush(&mut client.outgoing, &mut client.stream)?;
        if client.outgoing.len() < GEOMETRY_FRAME_SIZE {
            client.tail_geometry = false;
        }
        if let Some(deadline) = client.closing {
            return Ok(!client.outgoing.is_empty() && Instant::now() < deadline);
        }
        Ok(!client.handshake_expired())
    }

    fn parse_messages(&mut self, client: &mut Connection) {
        let mut incoming = std::mem::take(&mut client.incoming);
        let mut consumed = 0;
        client.input_blocked = false;
        while client.closing.is_none() {
            let Some(header) = incoming[consumed..].first_chunk::<HEADER_SIZE>() else {
                break;
            };
            let [kind, a, b, c, d] = *header;
            let length = u32::from_be_bytes([a, b, c, d]) as usize;
            if length > MAX_FRAME {
                client.end("Local terminal frame is too large");
                break;
            }
            let start = consumed + HEADER_SIZE;
            let end = start + length;
            let Some(payload) = incoming.get(start..end) else {
                break;
            };
            // An operation can generate an acknowledgement. Pause before
            // dispatch so the grant and its response cannot get separated.
            if !client.can_queue(CONTROL_FRAME_SIZE) || self.waiting_for_pty(client, kind, length) {
                client.input_blocked = true;
                break;
            }
            consumed = end;
            let result = match client.attachment {
                Some(attachment) => self.handle_message(client, attachment, kind, payload),
                None if kind == STOP_SESSION => self.stop_session_request(client, payload),
                None => self.open_attachment(client, kind, payload),
            };
            if let Err(error) = result {
                client.end(&error.to_string());
            }
        }
        incoming.drain(..consumed);
        client.incoming = incoming;
    }

    fn waiting_for_pty(&self, client: &Connection, kind: u8, length: usize) -> bool {
        let Some(attachment) = client.attachment else {
            return false;
        };
        let Some(session) = self.sessions.get(&attachment.session) else {
            return false;
        };
        if !session.controller.permits(attachment.client) {
            return false;
        }
        match kind {
            INPUT => length > MAX_QUEUE - session.pending_input.len(),
            RESIZE => !session.pending_input.is_empty(),
            _ => false,
        }
    }

    fn open_attachment(
        &mut self,
        client: &mut Connection,
        kind: u8,
        payload: &[u8],
    ) -> io::Result<()> {
        let (attachment, launch) = Attachment::parse(kind, payload)?;
        let id = attachment.session;
        // Reserve a separate command socket even when the workspace fills its
        // attachment budget and the controller's input queue is stalled.
        if !self.can_admit(
            self.sessions.len() + usize::from(launch.is_some()),
            self.connections.len() + 2,
        ) {
            return Err(io::Error::other("Local terminal descriptor budget reached"));
        }
        if let Some(options) = launch {
            if self.sessions.contains_key(&id) {
                return Err(io::Error::other(
                    "A terminal session with this identifier is already running",
                ));
            }
            if self.used_identifiers.contains(&id) {
                return Err(io::Error::other(
                    "This terminal session identifier has already ended",
                ));
            }
            if self.sessions.len() + self.stopping_shells.len() >= MAX_SESSIONS {
                return Err(io::Error::other("Local terminal session limit reached"));
            }
            if self.used_identifiers.len() >= MAX_USED_IDENTIFIERS {
                return Err(io::Error::other(
                    "Local terminal lifetime launch limit reached",
                ));
            }
            let pty = self.shell.start(options).map_err(|error| {
                eprintln!("Could not start local terminal shell {id:x?}: {error}");
                io::Error::other("Could not start terminal shell. Check the configured shell and working directory.")
            })?;
            self.sessions.insert(
                id,
                ManagedSession {
                    pty,
                    controller: Controller::new(attachment.client),
                    pending_input: VecDeque::new(),
                },
            );
            self.used_identifiers.insert(id);
        }
        let session = self
            .sessions
            .get(&id)
            .filter(|session| session.controller.is_legacy() == attachment.client.is_none())
            .ok_or_else(|| io::Error::other("No live terminal session matches this identifier"))?;
        if let Some((&fd, _)) = self
            .connections
            .iter()
            .find(|(_, active)| active.closing.is_none() && active.attachment == Some(attachment))
        {
            // An authenticated reconnect replaces only its own socket. Ownership
            // and previously accepted input belong to the session, not the socket.
            self.connections.remove(&fd);
        }
        client.attachment = Some(attachment);
        let mut identity = [0; 8];
        identity[..4].copy_from_slice(&std::process::id().to_be_bytes());
        identity[4..].copy_from_slice(&session.pty.child.id().to_be_bytes());
        client.queue(READY, &identity);
        if attachment.client.is_some() {
            client.control(CONTROL, self.control_state(attachment, Some(client)));
        }
        Ok(())
    }

    fn stop_session_request(&mut self, client: &mut Connection, payload: &[u8]) -> io::Result<()> {
        let invalid = || io::Error::other("A session, client and expected controller are required");
        let (identity, expected) = payload.split_first_chunk::<32>().ok_or_else(invalid)?;
        let (attachment, _) = Attachment::parse(VIEW_ATTACH, identity)?;
        let session = self
            .sessions
            .get(&attachment.session)
            .filter(|session| !session.controller.is_legacy())
            .ok_or_else(|| io::Error::other("No live terminal session matches this identifier"))?;
        if expected.len() != 24 {
            return Err(invalid());
        }
        if !session.controller.permits(attachment.client)
            || expected != session.controller.identified_revision()
        {
            return Err(io::Error::other(
                "Terminal control changed. Refresh and try again.",
            ));
        }
        self.stop_session(client, attachment.session);
        Ok(())
    }

    fn stop_session(&mut self, client: &mut Connection, id: Identifier) {
        if let Some(session) = self.sessions.remove(&id) {
            self.stopping_shells.push(session.pty.begin_stop());
        }
        self.finish_session(id, "Terminal session stopped");
        client.end("Terminal session stopped");
    }

    fn handle_message(
        &mut self,
        client: &mut Connection,
        attachment: Attachment,
        kind: u8,
        payload: &[u8],
    ) -> io::Result<()> {
        let id = attachment.session;
        let session = self
            .sessions
            .get_mut(&id)
            .ok_or_else(|| io::Error::other("Terminal session is unavailable"))?;
        let is_controller = session.controller.permits(attachment.client);
        match (kind, payload, attachment.client) {
            (DETACH, [], Some(_)) => client.end("Detached from local terminal session"),
            (INPUT | RESIZE | STOP, _, Some(_)) if !is_controller => {
                client.control(
                    CONTROL_REJECTED,
                    self.control_state(attachment, Some(client)),
                );
            }
            (STOP, [], Some(_)) => self.stop_session(client, id),
            (INPUT, _, _) => session.pending_input.extend(payload),
            (RESIZE, [a, b, c, d], _) => {
                session
                    .pty
                    .resize(u16::from_be_bytes([*a, *b]), u16::from_be_bytes([*c, *d]))?;
                if attachment.client.is_some() {
                    client.geometry(payload);
                    for viewer in self.active_attachments(id) {
                        viewer.geometry(payload);
                    }
                }
            }
            (TAKE_CONTROL | RELEASE_CONTROL, _, Some(requester)) => {
                let expected: [u8; 24] = payload.try_into().map_err(|_| {
                    io::Error::other("A terminal controller identity and revision are required")
                })?;
                let accepted = session.controller.change(kind, requester, expected)?;
                let response = if accepted { CONTROL } else { CONTROL_REJECTED };
                client.control(response, self.control_state(attachment, Some(client)));
            }
            _ => return Err(io::Error::other("Invalid terminal message")),
        }
        Ok(())
    }

    fn control_state(&self, attachment: Attachment, current: Option<&Connection>) -> [u8; 25] {
        let Some(session) = self.sessions.get(&attachment.session) else {
            return [0; 25];
        };
        let controller = &session.controller;
        let target = Attachment {
            session: attachment.session,
            client: controller.owner,
        };
        let connected = controller.owner.is_some()
            && current
                .into_iter()
                .chain(self.connections.values())
                .any(|client| client.closing.is_none() && client.attachment == Some(target));
        let mut state = [0; 25];
        state[..24].copy_from_slice(&controller.identified_revision());
        state[24] = u8::from(connected);
        state
    }

    fn publish_control(&mut self) {
        let mut changes = Vec::new();
        for (fd, client) in &self.connections {
            if let Some(attachment) = client.attachment.filter(|active| active.client.is_some()) {
                if client.closing.is_none() {
                    let state = self.control_state(attachment, None);
                    if client.observed_control != Some(state) {
                        changes.push((*fd, state));
                    }
                }
            }
        }
        for (fd, state) in changes {
            if let Some(client) = self.connections.get_mut(&fd) {
                client.control(CONTROL, state);
            }
        }
    }

    fn update_session(
        &mut self,
        id: Identifier,
        session: &mut ManagedSession,
        events: i16,
    ) -> io::Result<bool> {
        let status = session.pty.child.try_wait()?;
        if events & libc::POLLNVAL != 0 {
            return Err(io::Error::other("Terminal PTY descriptor is unavailable"));
        }
        if events & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 || status.is_some() {
            let drained = self.read_output(id, session)?;
            if let Some(status) = status.filter(|_| drained) {
                self.finish_session(id, &format!("Terminal shell ended ({status})"));
                return Ok(false);
            }
        }
        if status.is_none() && events & libc::POLLOUT != 0 && events & libc::POLLHUP == 0 {
            flush(&mut session.pending_input, &mut session.pty.master)?;
        }
        Ok(true)
    }

    fn read_output(&mut self, id: Identifier, session: &mut ManagedSession) -> io::Result<bool> {
        let mut bytes = [0; READ_SIZE];
        for _ in 0..4 {
            let capacity = self.output_capacity(id, session);
            if capacity == 0 {
                return Ok(false);
            }
            match session.pty.master.read(&mut bytes[..capacity]) {
                Ok(0) => return Ok(true),
                Ok(count) => {
                    for client in self.active_attachments(id) {
                        let packet = &bytes[..count];
                        let reserve = if client
                            .attachment
                            .is_some_and(|active| active.client.is_some())
                        {
                            CONTROL_RESERVE
                        } else {
                            0
                        };
                        if client.outgoing.len() + HEADER_SIZE + packet.len() <= MAX_QUEUE - reserve
                        {
                            client.queue(OUTPUT, packet);
                        } else {
                            client.end("Local terminal output fell behind. Reattach to continue.");
                        }
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

    fn output_capacity(&self, id: Identifier, session: &ManagedSession) -> usize {
        self.connections
            .values()
            .find(|client| {
                client.closing.is_none()
                    && client.attachment.is_some_and(|attachment| {
                        attachment.session == id && session.controller.permits(attachment.client)
                    })
            })
            .map_or(READ_SIZE, |client| {
                let ceiling = if session.controller.is_legacy() {
                    MAX_QUEUE
                } else {
                    MAX_QUEUE - CONTROL_RESERVE
                };
                READ_SIZE.min(ceiling.saturating_sub(client.outgoing.len() + HEADER_SIZE))
            })
    }

    fn active_attachments(&mut self, id: Identifier) -> impl Iterator<Item = &mut Connection> {
        self.connections.values_mut().filter(move |client| {
            client.closing.is_none() && client.attachment.is_some_and(|active| active.session == id)
        })
    }

    fn finish_session(&mut self, id: Identifier, message: &str) {
        for client in self.active_attachments(id) {
            client.end(message);
        }
    }
}

impl<Authenticate> Drop for Server<Authenticate> {
    fn drop(&mut self) {
        self.stopping_shells.extend(
            self.sessions
                .drain()
                .map(|(_, session)| session.pty.begin_stop()),
        );
        while !self.stopping_shells.is_empty() {
            reap_shells(&mut self.stopping_shells);
            if !self.stopping_shells.is_empty() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

fn descriptor_budget() -> io::Result<usize> {
    let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
    check(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, limit.as_mut_ptr()) })?;
    let limit = unsafe { limit.assume_init() };
    Ok(usize::try_from(limit.rlim_cur)
        .unwrap_or(usize::MAX)
        .saturating_sub(FD_HEADROOM))
}

fn descriptor_exhausted(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::EMFILE | libc::ENFILE))
}

fn reap_shells(shells: &mut Vec<StoppingShell>) {
    shells.retain_mut(|shell| !shell.reaped());
}

struct ManagedSession {
    pty: Session,
    controller: Controller,
    pending_input: VecDeque<u8>,
}

struct Controller {
    owner: Option<Identifier>,
    revision: u64,
}

impl Controller {
    fn new(owner: Option<Identifier>) -> Self {
        let revision = u64::from(owner.is_some());
        Self { owner, revision }
    }

    fn is_legacy(&self) -> bool {
        self.revision == 0
    }

    fn permits(&self, client: Option<Identifier>) -> bool {
        self.is_legacy() || client.is_some_and(|id| self.owner == Some(id))
    }

    fn identified_revision(&self) -> [u8; 24] {
        let mut state = [0; 24];
        state[..16].copy_from_slice(&self.owner.unwrap_or(NO_OWNER));
        state[16..].copy_from_slice(&self.revision.to_be_bytes());
        state
    }

    fn change(&mut self, kind: u8, requester: Identifier, expected: [u8; 24]) -> io::Result<bool> {
        if expected != self.identified_revision()
            || (kind == RELEASE_CONTROL && self.owner != Some(requester))
        {
            return Ok(false);
        }
        let owner = (kind == TAKE_CONTROL).then_some(requester);
        if self.owner != owner {
            self.revision = self
                .revision
                .checked_add(1)
                .ok_or_else(|| io::Error::other("Terminal controller revision exhausted"))?;
            self.owner = owner;
        }
        Ok(true)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Attachment {
    session: Identifier,
    client: Option<Identifier>,
}

impl Attachment {
    fn parse(kind: u8, payload: &[u8]) -> io::Result<(Self, Option<LaunchOptions>)> {
        let invalid =
            || io::Error::other("A terminal session and local client identifier are required");
        match kind {
            START | ATTACH => {
                let session = payload.try_into().map_err(|_| {
                    io::Error::other("A 16-byte terminal session identifier is required")
                })?;
                let launch = (kind == START).then(LaunchOptions::default);
                Ok((
                    Self {
                        session,
                        client: None,
                    },
                    launch,
                ))
            }
            LAUNCH | VIEW_ATTACH => {
                let (session, payload) = payload.split_first_chunk::<16>().ok_or_else(invalid)?;
                let (client, settings) = payload.split_first_chunk::<16>().ok_or_else(invalid)?;
                if *client == NO_OWNER || *session == NO_OWNER {
                    return Err(invalid());
                }
                let launch = if kind == LAUNCH {
                    Some(LaunchOptions::parse(settings)?)
                } else if settings.is_empty() {
                    None
                } else {
                    return Err(io::Error::other(
                        "Unexpected local terminal attachment settings",
                    ));
                };
                Ok((
                    Self {
                        session: *session,
                        client: Some(*client),
                    },
                    launch,
                ))
            }
            _ => Err(io::Error::other(
                "Start or attach to a terminal session first",
            )),
        }
    }
}

struct Connection {
    stream: UnixStream,
    peer_events: PeerEvents,
    incoming: Vec<u8>,
    outgoing: VecDeque<u8>,
    input_blocked: bool,
    attachment: Option<Attachment>,
    observed_control: Option<[u8; 25]>,
    handshake_deadline: Instant,
    closing: Option<Instant>,
    tail_geometry: bool,
}

impl Connection {
    fn new(stream: UnixStream) -> io::Result<Self> {
        Ok(Self {
            peer_events: PeerEvents::new(&stream)?,
            stream,
            incoming: Vec::new(),
            outgoing: VecDeque::new(),
            input_blocked: false,
            attachment: None,
            observed_control: None,
            handshake_deadline: Instant::now() + HANDSHAKE_TIMEOUT,
            closing: None,
            tail_geometry: false,
        })
    }

    fn poll_descriptor(&self) -> libc::pollfd {
        let mut events = 0;
        if self.closing.is_none() && !self.input_blocked {
            events |= libc::POLLIN;
        }
        if !self.outgoing.is_empty() {
            events |= libc::POLLOUT;
        }
        poll_descriptor(self.stream.as_raw_fd(), events)
    }

    fn handshake_expired(&self) -> bool {
        self.attachment.is_none() && Instant::now() >= self.handshake_deadline
    }

    fn queue(&mut self, kind: u8, bytes: &[u8]) {
        queue_frame(&mut self.outgoing, kind, bytes);
        self.tail_geometry = kind == GEOMETRY;
    }

    fn can_queue(&self, length: usize) -> bool {
        self.outgoing.len() + length <= MAX_QUEUE
    }

    fn geometry(&mut self, geometry: &[u8]) {
        if self.tail_geometry {
            // A completely unsent geometry at the tail has no output or
            // acknowledgement between it and the replacement.
            self.outgoing
                .truncate(self.outgoing.len() - GEOMETRY_FRAME_SIZE);
        }
        self.queue_bounded(GEOMETRY, geometry);
    }

    fn queue_bounded(&mut self, kind: u8, bytes: &[u8]) {
        if self.outgoing.len() + HEADER_SIZE + bytes.len() > MAX_QUEUE {
            self.end("Local terminal output fell behind. Reattach to continue.");
        } else {
            self.queue(kind, bytes);
        }
    }

    fn control(&mut self, kind: u8, state: [u8; 25]) {
        self.queue_bounded(kind, &state);
        self.observed_control = Some(state);
    }

    fn end(&mut self, message: &str) {
        if self.closing.is_none() {
            self.queue(END, message.as_bytes());
            self.closing = Some(Instant::now() + HANDSHAKE_TIMEOUT);
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

fn poll_descriptor(fd: RawFd, events: i16) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
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

#[cfg(test)]
#[path = "server_tests.rs"]
mod tests;
