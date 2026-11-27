use super::*;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicU32, Ordering},
    Arc,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub(crate) struct TestDirectory(pub(crate) PathBuf);

impl TestDirectory {
    pub(crate) fn new() -> io::Result<Self> {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = PathBuf::from(format!(
            "/tmp/myterm-local-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not clean up test directory: {error}");
        }
    }
}

struct TestServer {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<io::Result<()>>>,
    _directory: TestDirectory,
}

impl TestServer {
    fn new() -> io::Result<Self> {
        Self::with_authentication(|_| Ok(()))
    }

    fn with_authentication(
        authenticate: impl Fn(&UnixStream) -> io::Result<()> + Send + 'static,
    ) -> io::Result<Self> {
        let directory = TestDirectory::new()?;
        let path = directory.0.join("s");
        let mut server = Server::bind(&path, authenticate, Shell::for_test())?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let worker = thread::spawn(move || {
            while !stopping.load(Ordering::Acquire) {
                server.step(100)?;
            }
            Ok(())
        });
        Ok(Self {
            path,
            stop,
            worker: Some(worker),
            _directory: directory,
        })
    }

    fn connect(&self) -> io::Result<UnixStream> {
        let client = UnixStream::connect(&self.path)?;
        client.set_read_timeout(Some(Duration::from_secs(5)))?;
        Ok(client)
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            if let Err(error) = worker.join().unwrap() {
                panic!("Terminal server failed: {error}");
            }
        }
    }
}

pub(crate) fn send(socket: &mut UnixStream, kind: u8, payload: &[u8]) -> io::Result<()> {
    socket.write_all(&[kind])?;
    socket.write_all(&(payload.len() as u32).to_be_bytes())?;
    socket.write_all(payload)
}

pub(crate) fn receive(socket: &mut UnixStream) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0; 5];
    socket.read_exact(&mut header)?;
    let size = u32::from_be_bytes(header[1..].try_into().unwrap());
    assert!(size <= 65_536);
    let mut payload = vec![0; size as usize];
    socket.read_exact(&mut payload)?;
    Ok((header[0], payload))
}

fn receive_output(socket: &mut UnixStream, expected: &str) -> io::Result<()> {
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains(expected) {
        let (kind, bytes) = receive(socket)?;
        if kind == 0x88 {
            continue;
        }
        assert_eq!(kind, 0x82, "{}", String::from_utf8_lossy(&bytes));
        output.extend(bytes);
        assert!(output.len() < 65_536);
    }
    Ok(())
}

#[test]
fn starts_a_real_shell_and_receives_output_over_the_socket() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    send(&mut client, 1, &[42; 16])?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);
    assert_eq!(identity.len(), 8);
    assert_eq!(&identity[..4], &std::process::id().to_be_bytes());
    let shell_pid = u32::from_be_bytes(identity[4..].try_into().unwrap());
    send(&mut client, 3, b"printf 'actual-pid=%s\\n' \"$$\"\n")?;
    receive_output(&mut client, &format!("actual-pid={shell_pid}"))?;
    send(&mut client, 3, b"exit\n")?;
    loop {
        let (kind, payload) = receive(&mut client)?;
        if kind == 0x83 {
            assert!(String::from_utf8_lossy(&payload).contains("exit status: 0"));
            break;
        }
        assert_eq!(kind, 0x82);
    }
    Ok(())
}

#[test]
fn reattaches_to_the_same_shell_after_a_client_disconnects() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut first = server.connect()?;
    let session_id = [13; 16];
    send(&mut first, 1, &session_id)?;
    let (kind, identity) = receive(&mut first)?;
    assert_eq!(kind, 0x81);
    send(
        &mut first,
        3,
        b"counter=41; printf 'counter=%s\\n' \"$counter\"\n",
    )?;
    receive_output(&mut first, "counter=41\r\n")?;
    drop(first);

    let mut unknown = server.connect()?;
    send(&mut unknown, 2, &[0; 16])?;
    let (kind, payload) = receive(&mut unknown)?;
    assert_eq!(kind, 0x83);
    assert!(String::from_utf8_lossy(&payload).contains("No live terminal session"));
    drop(unknown);

    let mut duplicate = server.connect()?;
    send(&mut duplicate, 1, &session_id)?;
    let (kind, payload) = receive(&mut duplicate)?;
    assert_eq!(kind, 0x83);
    assert!(String::from_utf8_lossy(&payload).contains("already running"));
    drop(duplicate);

    let mut next = server.connect()?;
    send(&mut next, 2, &session_id)?;
    assert_eq!(receive(&mut next)?, (0x81, identity.clone()));
    send(&mut next, 4, &[0, 91, 0, 37])?;
    send(
        &mut next,
        3,
        b"read rows cols <<EOF\n$(stty size)\nEOF\nprintf 'counter=%s rows=%s cols=%s pid=%s\\n' \"$((counter+1))\" \"$rows\" \"$cols\" \"$$\"\n",
    )?;
    let shell_pid = u32::from_be_bytes(identity[4..].try_into().unwrap());
    receive_output(
        &mut next,
        &format!("counter=42 rows=37 cols=91 pid={shell_pid}"),
    )?;
    send(&mut next, 3, b"exit\n")?;
    loop {
        let (kind, payload) = receive(&mut next)?;
        if kind == 0x83 {
            assert!(String::from_utf8_lossy(&payload).contains("exit status: 0"));
            break;
        }
        assert_eq!(kind, 0x82);
    }
    drop(next);

    let mut gone = server.connect()?;
    send(&mut gone, 2, &session_id)?;
    let (kind, payload) = receive(&mut gone)?;
    assert_eq!(kind, 0x83);
    assert!(String::from_utf8_lossy(&payload).contains("No live terminal session"));
    Ok(())
}

#[test]
fn an_unexpected_same_uid_client_cannot_start_a_shell() -> io::Result<()> {
    let server = TestServer::with_authentication(|socket| {
        crate::authentication::ClientAuthentication::for_team("TESTTEAM01")?.authenticate(socket)
    })?;
    let mut client = server.connect()?;
    match send(&mut client, 1, &[42; 16]) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => {}
        Err(error) => return Err(error),
    }
    assert_eq!(
        receive(&mut client)?,
        (0x83, b"Untrusted local terminal client".to_vec())
    );
    assert_eq!(client.read(&mut [0; 1])?, 0);
    Ok(())
}

#[test]
fn reclaims_a_stale_socket_but_preserves_a_live_socket_and_other_files() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let stale = crate::socket::Socket::bind(&path)?;
    // Move the published inode aside during normal cleanup to reproduce the
    // path and ownership record an interrupted daemon leaves behind.
    let orphan = directory.0.join("orphan");
    fs::rename(&path, &orphan)?;
    drop(stale);
    fs::rename(orphan, &path)?;
    let authenticate = |_: &UnixStream| Ok(());

    let server = Server::bind(&path, authenticate, Shell::for_test())?;
    let duplicate = Server::bind(&path, authenticate, Shell::for_test());
    assert!(duplicate.is_err());
    UnixStream::connect(&path)?;
    drop(server);
    assert!(!path.exists());

    fs::write(&path, b"keep")?;
    assert!(Server::bind(&path, authenticate, Shell::for_test()).is_err());
    assert_eq!(fs::read(&path)?, b"keep");
    Ok(())
}

#[test]
fn preserves_an_external_live_listener_even_with_a_full_accept_queue() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let listener = UnixListener::bind(&path)?;
    crate::session::check(unsafe { libc::listen(listener.as_raw_fd(), 1) })?;
    let authenticate = |_: &UnixStream| Ok(());

    let unoccupied_backlog = Server::bind(&path, authenticate, Shell::for_test());
    assert!(matches!(unoccupied_backlog, Err(error) if error.kind() == io::ErrorKind::AddrInUse));

    let queued = UnixStream::connect(&path)?;
    let full_backlog = UnixStream::connect(&path).expect_err("Darwin backlog should be full");
    assert_eq!(full_backlog.kind(), io::ErrorKind::ConnectionRefused);
    let candidate = Server::bind(&path, authenticate, Shell::for_test());
    assert!(matches!(candidate, Err(error) if error.kind() == io::ErrorKind::AddrInUse));

    let accepted = listener.accept()?;
    drop(accepted);
    drop(queued);
    UnixStream::connect(&path)?;
    drop(listener);
    let unrecorded = Server::bind(&path, authenticate, Shell::for_test());
    assert!(matches!(unrecorded, Err(error) if error.kind() == io::ErrorKind::AddrInUse));
    fs::write(directory.0.join("s.lock"), b"incomplete")?;
    let incomplete = Server::bind(&path, authenticate, Shell::for_test());
    assert!(matches!(incomplete, Err(error) if error.kind() == io::ErrorKind::AddrInUse));
    assert!(path.exists());
    Ok(())
}

#[test]
fn slow_client_receives_large_output_in_order_before_shell_exit() -> io::Result<()> {
    const EXPECTED: usize = 2 * 1024 * 1024;
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    send(&mut client, 1, &[14; 16])?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);
    assert_eq!(&identity[..4], &std::process::id().to_be_bytes());
    send(
        &mut client,
        3,
        b"head -c 2097152 /dev/zero; printf 'flushed=%s\\n' \"$$\"; exit\n",
    )?;
    thread::sleep(Duration::from_millis(250));

    let shell_pid = u32::from_be_bytes(identity[4..].try_into().unwrap());
    let marker = format!("flushed={shell_pid}\r\n");
    let mut output = Vec::new();
    loop {
        let (kind, payload) = receive(&mut client)?;
        if kind == 0x83 {
            assert!(
                String::from_utf8_lossy(&payload).contains("exit status: 0"),
                "{}",
                String::from_utf8_lossy(&payload)
            );
            break;
        }
        assert_eq!(kind, 0x82);
        output.extend(payload);
        assert!(output.len() < EXPECTED + 1024);
    }
    let body = output
        .iter()
        .position(|byte| *byte == 0)
        .expect("missing streamed output");
    assert!(output[body..body + EXPECTED].iter().all(|byte| *byte == 0));
    assert!(output[body + EXPECTED..].starts_with(marker.as_bytes()));
    Ok(())
}

#[test]
fn socket_input_waits_for_the_pty_without_dropping_bytes() -> io::Result<()> {
    const EXPECTED: usize = 512 * 1024;
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    client.set_write_timeout(Some(Duration::from_secs(5)))?;
    send(&mut client, 1, &[15; 16])?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);
    send(
        &mut client,
        3,
        b"stty raw -echo; printf 'input-ready\\r\\n'; sleep 0.5; n=$(head -c 524288 | tr -cd q | wc -c | tr -d ' '); stty sane; printf 'received=%s pid=%s\\n' \"$n\" \"$$\"\n",
    )?;
    receive_output(&mut client, "input-ready\r\n")?;
    let block = vec![b'q'; 65_536];
    for _ in 0..EXPECTED / block.len() {
        send(&mut client, 3, &block)?;
    }
    let shell_pid = u32::from_be_bytes(identity[4..].try_into().unwrap());
    receive_output(&mut client, &format!("received={EXPECTED} pid={shell_pid}"))?;
    Ok(())
}

#[test]
fn an_abrupt_detach_drains_blocked_output_and_preserves_both_processes() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    send(&mut client, 1, &[16; 16])?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);
    assert_eq!(&identity[..4], &std::process::id().to_be_bytes());

    let marker_file = server.path.with_file_name("done");
    let command = format!(
        "kept=43; head -c 2097152 /dev/zero; printf '%s' \"$$\" > {}\n",
        marker_file.display()
    );
    send(&mut client, 3, command.as_bytes())?;
    thread::sleep(Duration::from_millis(250));
    assert!(
        !marker_file.exists(),
        "terminal output should have applied backpressure"
    );
    drop(client);

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let shell_pid = u32::from_be_bytes(identity[4..].try_into().unwrap());
    loop {
        match fs::read_to_string(&marker_file) {
            Ok(marker) if marker == shell_pid.to_string() => break,
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        assert!(
            std::time::Instant::now() < deadline,
            "detached PTY did not drain"
        );
        thread::sleep(Duration::from_millis(20));
    }

    let mut reattached = server.connect()?;
    send(&mut reattached, 2, &[16; 16])?;
    assert_eq!(receive(&mut reattached)?, (0x81, identity));
    send(
        &mut reattached,
        3,
        b"printf 'same=%s pid=%s\\n' \"$kept\" \"$$\"\n",
    )?;
    receive_output(&mut reattached, &format!("same=43 pid={shell_pid}"))?;
    Ok(())
}

#[test]
fn shutting_down_the_server_reaps_its_owned_shell() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    send(&mut client, 1, &[17; 16])?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);
    let shell_pid = libc::pid_t::from_be_bytes(identity[4..].try_into().unwrap());
    send(
        &mut client,
        3,
        b"printf 'shell=%s\\n' \"$$\"; exec /bin/sleep 30\n",
    )?;
    receive_output(&mut client, &format!("shell={shell_pid}"))?;
    drop(server);
    assert_eq!(unsafe { libc::kill(shell_pid, 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    Ok(())
}

#[test]
fn an_abrupt_detach_is_seen_while_terminal_input_is_backpressured() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    client.set_write_timeout(Some(Duration::from_millis(250)))?;
    let id = [18; 16];
    send(&mut client, 1, &id)?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, 0x81);

    send(
        &mut client,
        3,
        b"stty raw -echo; printf 'paste-paused\\r\\n'; sleep 5\n",
    )?;
    receive_output(&mut client, "paste-paused\r\n")?;
    let block = vec![b'q'; 65_536];
    let blocked = (0..16).try_for_each(|_| send(&mut client, 3, &block));
    let error = blocked.expect_err("the stalled PTY should backpressure the socket");
    assert!(matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    ));
    drop(client);

    let mut reattached = server.connect()?;
    reattached.set_read_timeout(Some(Duration::from_secs(1)))?;
    send(&mut reattached, 2, &id)?;
    let (kind, payload) = receive(&mut reattached)?;
    assert_eq!(kind, 0x81, "{}", String::from_utf8_lossy(&payload));
    assert_eq!(payload, identity);
    Ok(())
}

#[test]
fn independent_configured_ptys_reattach_and_stop_without_affecting_each_other() -> io::Result<()> {
    let server = TestServer::new()?;
    let directory = TestDirectory::new()?;
    let mut alpha = server.connect()?;
    let mut beta = server.connect()?;
    let alpha_id = [[31; 16], [32; 16]].concat();
    let beta_id = [[33; 16], [32; 16]].concat();
    let mut launch = alpha_id.clone();
    launch.extend(
        format!(
            r#"{{"shell":"/bin/sh","arguments":["-i"],"cwd":"{}","columns":90,"rows":36,"environment":{{"MYTERM_TEST_PROFILE":"expected-profile","MYTERM_STARTUP_PARENT_PID":"123"}}}}"#,
            directory.0.display()
        )
        .as_bytes(),
    );
    send(&mut alpha, 5, &launch)?;
    assert_eq!(receive(&mut alpha)?.0, 0x81);
    assert_eq!(receive(&mut alpha)?.0, 0x84);
    send(&mut beta, 5, &beta_id)?;
    let (kind, beta_identity) = receive(&mut beta)?;
    assert_eq!(kind, 0x81);
    assert_eq!(receive(&mut beta)?.0, 0x84);

    send(&mut beta, 4, &[0, 120, 0, 50])?;
    send(
        &mut beta,
        3,
        b"counter=40; printf 'beta geometry=%s\\n' \"$(stty size)\"\n",
    )?;
    receive_output(&mut beta, "beta geometry=50 120\r\n")?;
    send(
        &mut alpha,
        3,
        b"printf 'profile=%s cwd=%s size=%s counter=%s\\n' \"$MYTERM_TEST_PROFILE\" \"$PWD\" \"$(stty size)\" \"$counter\"\n",
    )?;
    let canonical_directory = directory.0.canonicalize()?;
    // Darwin can report the logical /tmp path or its physical /private/tmp spelling.
    receive_output(
        &mut alpha,
        &format!(
            "{} size=36 90 counter=\r\n",
            canonical_directory.file_name().unwrap().to_string_lossy()
        ),
    )?;
    send(
        &mut alpha,
        3,
        b"printf 'profile=%s\\n' \"$MYTERM_TEST_PROFILE\"\n",
    )?;
    receive_output(&mut alpha, "profile=expected-profile\r\n")?;

    send(&mut beta, 10, &[])?;
    receive_frame(&mut beta, 0x83)?;
    let mut reattached = server.connect()?;
    send(&mut reattached, 6, &beta_id)?;
    assert_eq!(receive(&mut reattached)?, (0x81, beta_identity));
    assert_eq!(receive(&mut reattached)?.0, 0x84);
    send(
        &mut reattached,
        3,
        b"printf 'reattached counter=%s\\n' \"$((counter+2))\"\n",
    )?;
    receive_output(&mut reattached, "reattached counter=42\r\n")?;

    send(&mut alpha, 9, &[])?;
    let payload = receive_frame(&mut alpha, 0x83)?;
    assert!(String::from_utf8_lossy(&payload).contains("stopped"));
    let mut stale = server.connect()?;
    send(&mut stale, 6, &alpha_id)?;
    assert_eq!(
        receive(&mut stale)?,
        (
            0x83,
            b"No live terminal session matches this identifier".to_vec()
        ),
    );
    let mut retry = server.connect()?;
    send(&mut retry, 5, &launch)?;
    assert_eq!(
        receive(&mut retry)?,
        (
            0x83,
            b"This terminal session identifier has already ended".to_vec()
        ),
    );
    send(
        &mut reattached,
        3,
        b"printf 'beta still live: %s\\n' \"$(stty size)\"\n",
    )?;
    receive_output(&mut reattached, "beta still live: 50 120\r\n")?;
    Ok(())
}

fn receive_frame(socket: &mut UnixStream, expected: u8) -> io::Result<Vec<u8>> {
    let mut ignored_output = 0;
    while ignored_output < 65_536 {
        let (kind, payload) = receive(socket)?;
        if kind == expected {
            return Ok(payload);
        }
        assert_eq!(
            kind,
            0x82,
            "Unexpected frame {kind:#x} before {expected:#x}: {:?}",
            String::from_utf8_lossy(&payload)
        );
        ignored_output += payload.len();
    }
    Err(io::Error::other(format!(
        "Expected frame {expected:#x} did not arrive"
    )))
}

fn control(owner: [u8; 16], revision: u64, connected: bool) -> Vec<u8> {
    [&owner[..], &revision.to_be_bytes(), &[u8::from(connected)]].concat()
}

#[test]
fn viewer_requires_explicit_current_revision_to_control_and_resize() -> io::Result<()> {
    let server = TestServer::new()?;
    let session = [35; 16];
    let alice = [36; 16];
    let bob = [37; 16];
    let mut owner = server.connect()?;
    send(&mut owner, 5, &[session, alice].concat())?;
    let (kind, identity) = receive(&mut owner)?;
    assert_eq!(kind, 0x81);
    let first = control(alice, 1, true);
    assert_eq!(receive(&mut owner)?, (0x84, first.clone()));

    let mut viewer = server.connect()?;
    send(&mut viewer, 6, &[session, bob].concat())?;
    assert_eq!(receive(&mut viewer)?, (0x81, identity.clone()));
    assert_eq!(receive_frame(&mut viewer, 0x84)?, first);

    for (kind, payload) in [(3, &b"counter=wrong\n"[..]), (4, &[0, 92, 0, 35]), (9, &[])] {
        send(&mut viewer, kind, payload)?;
        assert_eq!(receive_frame(&mut viewer, 0x85)?, first);
    }
    send(
        &mut owner,
        3,
        b"printf 'unchanged=%s, geometry=%s\\n' \"$counter\" \"$(stty size)\"\n",
    )?;
    receive_output(&mut viewer, "unchanged=, geometry=24 80\r\n")?;
    drop(owner);
    assert_eq!(receive_frame(&mut viewer, 0x84)?, control(alice, 1, false));

    send(&mut viewer, 7, &control(alice, 0, false)[..24])?;
    assert_eq!(receive_frame(&mut viewer, 0x85)?, control(alice, 1, false));
    send(&mut viewer, 7, &first[..24])?;
    let second = control(bob, 2, true);
    assert_eq!(receive_frame(&mut viewer, 0x84)?, second);

    let mut displaced = server.connect()?;
    send(&mut displaced, 6, &[session, alice].concat())?;
    assert_eq!(receive(&mut displaced)?, (0x81, identity));
    assert_eq!(receive_frame(&mut displaced, 0x84)?, second);
    send(&mut displaced, 3, b"counter=still-wrong\n")?;
    assert_eq!(receive_frame(&mut displaced, 0x85)?, second);
    send(&mut viewer, 4, &[0, 110, 0, 44])?;
    assert_eq!(receive_frame(&mut displaced, 0x88)?, [0, 110, 0, 44]);
    send(
        &mut viewer,
        3,
        b"printf 'new-geometry=%s, counter=%s\\n' \"$(stty size)\" \"$counter\"\n",
    )?;
    receive_output(&mut displaced, "new-geometry=44 110, counter=\r\n")?;
    send(&mut viewer, 8, &second[..24])?;
    let released = control([0; 16], 3, false);
    assert_eq!(receive_frame(&mut displaced, 0x84)?, released);
    assert_eq!(receive_frame(&mut viewer, 0x88)?, [0, 110, 0, 44]);
    assert_eq!(receive_frame(&mut viewer, 0x84)?, released);
    send(&mut displaced, 7, &released[..24])?;
    assert_eq!(
        receive_frame(&mut displaced, 0x84)?,
        control(alice, 4, true)
    );
    Ok(())
}

fn receive_checkpoint(client: &mut UnixStream) -> io::Result<(Vec<u8>, u64, Vec<u8>)> {
    let (kind, identity) = receive(client)?;
    assert_eq!(kind, 0x81);
    assert_eq!(identity.len(), 9);
    assert_eq!(identity[8], 1);
    assert_eq!(receive(client)?.0, 0x84);
    let (kind, begin) = receive(client)?;
    assert_eq!(kind, 0x86);
    assert_eq!(begin.len(), 12);
    let sequence = u64::from_be_bytes(begin[..8].try_into().unwrap());
    let length = u32::from_be_bytes(begin[8..].try_into().unwrap()) as usize;
    assert!((1..=myterm_terminal_state::MAXIMUM_CHECKPOINT_BYTES).contains(&length));
    let mut checkpoint = Vec::with_capacity(length);
    while checkpoint.len() < length {
        let (kind, bytes) = receive(client)?;
        assert_eq!(kind, 0x87);
        assert!(!bytes.is_empty() && bytes.len() <= length - checkpoint.len());
        checkpoint.extend(bytes);
    }
    Ok((identity, sequence, checkpoint))
}

#[test]
fn real_pty_checkpoint_preserves_the_shell_and_the_server_alone_replies() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut first = server.connect()?;
    let gate = server.path.with_file_name("resume");
    let script = r#"
        /bin/stty raw -echo
        printf 'original\033[?1049h\033[Halternate\033[6'
        while [ ! -e "$1" ]; do /bin/sleep 0.02; done
        printf n
        reply=$(/bin/dd bs=1 count=7 2>/dev/null)
        [ "$reply" = "$(printf '\033[1;10R')" ] || exit 91
        printf '\033[?1049lreply-checked=%s' "$$"
        input=$(/bin/dd bs=1 count=1 2>/dev/null)
        [ "$input" = x ] || exit 92
    "#;
    let ids = [1; 32];
    let mut launch = ids.to_vec();
    let options = serde_json::json!({
        "shell": "/bin/sh", "arguments": ["-c", script, "sh", gate.to_str().unwrap()],
        "columns": 20, "rows": 6, "cellWidth": 9, "cellHeight": 16, "scrollback": 5000,
    });
    launch.extend(serde_json::to_vec(&options)?);
    send(&mut first, 11, &launch)?;
    let (identity, sequence, _) = receive_checkpoint(&mut first)?;
    send(&mut first, 13, &sequence.to_be_bytes())?;
    receive_output(&mut first, "alternate\u{1b}[6")?;
    drop(first);

    let mut old_client = server.connect()?;
    send(&mut old_client, 6, &ids)?;
    assert_eq!(
        receive(&mut old_client)?.0,
        0x83,
        "Raw attach must not bypass server query authority"
    );

    let mut probe = server.connect()?;
    send(&mut probe, 15, &ids)?;
    assert_eq!(
        receive(&mut probe)?.0,
        0x84,
        "Metadata lookup must work without importing state"
    );

    let mut fresh = server.connect()?;
    send(&mut fresh, 12, &ids)?;
    let (reattached, sequence, checkpoint) = receive_checkpoint(&mut fresh)?;
    assert_eq!(reattached, identity);
    let value: serde_json::Value = serde_json::from_slice(&checkpoint)?;
    assert_eq!(value["sequence"], sequence);
    assert_eq!(value["state"]["alternateActive"], true);
    assert_eq!(value["pending"], serde_json::json!([27, 91, 54]));

    // The shell finishes its query before the new client acknowledges import.
    fs::write(gate, [])?;
    let mut live = Vec::new();
    let shell_pid = u32::from_be_bytes(identity[4..8].try_into().unwrap());
    let marker = format!("reply-checked={shell_pid}");
    while !String::from_utf8_lossy(&live).contains(&marker) {
        let (kind, bytes) = receive(&mut fresh)?;
        assert_eq!(kind, 0x82);
        live.extend(bytes);
        assert!(live.len() < 8192);
    }
    assert!(live.starts_with(b"n\x1b[?1049l"));
    send(&mut fresh, 13, &sequence.to_be_bytes())?;
    send(&mut fresh, 3, b"x")?;
    let (kind, ended) = receive(&mut fresh)?;
    assert_eq!(kind, 0x83);
    assert!(String::from_utf8_lossy(&ended).contains("exit status: 0"));

    if let Some(path) = std::env::var_os("MYTERM_PTY_CHECKPOINT_FIXTURE") {
        fs::write(path, checkpoint)?;
    }
    if let Some(path) = std::env::var_os("MYTERM_PTY_OUTPUT_FIXTURE") {
        fs::write(path, live)?;
    }
    Ok(())
}

#[test]
fn checkpoint_attachment_fences_input_until_import_acknowledgement() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    let mut launch = [3; 32].to_vec();
    launch.extend(br#"{"columns":20,"rows":6,"cellWidth":9,"cellHeight":16}"#);
    send(&mut client, 11, &launch)?;
    receive_checkpoint(&mut client)?;
    send(&mut client, 3, b"echo should-not-appear\n")?;
    loop {
        let (kind, bytes) = receive(&mut client)?;
        if kind == 0x83 {
            assert_eq!(
                bytes,
                b"Apply the terminal checkpoint before sending requests"
            );
            break;
        }
        assert_eq!(kind, 0x82);
        assert!(!String::from_utf8_lossy(&bytes).contains("should-not-appear"));
    }
    Ok(())
}

#[test]
fn viewer_receives_controller_resize_after_snapshot_while_import_pending() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut owner = server.connect()?;
    let session_id = [4; 16];
    let owner_id = [5; 16];
    let viewer_id = [6; 16];
    let mut launch = [session_id, owner_id].concat();
    launch.extend(br#"{"columns":20,"rows":6,"cellWidth":9,"cellHeight":16}"#);
    send(&mut owner, 11, &launch)?;
    let (_, owner_cut, _) = receive_checkpoint(&mut owner)?;
    send(&mut owner, 13, &owner_cut.to_be_bytes())?;

    let mut viewer = server.connect()?;
    send(&mut viewer, 12, &[session_id, viewer_id].concat())?;
    let (_, viewer_cut, before) = receive_checkpoint(&mut viewer)?;
    let before: serde_json::Value = serde_json::from_slice(&before)?;
    assert_eq!(before["state"]["columns"], 20);

    let geometry = [0, 32, 0, 8, 0, 9, 0, 16];
    send(&mut owner, 4, &geometry)?;
    for connection in [&mut owner, &mut viewer] {
        loop {
            match receive(connection)? {
                (0x88, payload) => {
                    assert_eq!(payload, geometry);
                    break;
                }
                (0x82, _) => {}
                unexpected => panic!("unexpected frame: {unexpected:?}"),
            }
        }
    }
    send(&mut viewer, 13, &viewer_cut.to_be_bytes())?;

    let mut after = server.connect()?;
    send(&mut after, 12, &[session_id, viewer_id].concat())?;
    let (_, after_cut, after) = receive_checkpoint(&mut after)?;
    assert!(after_cut > viewer_cut);
    let after: serde_json::Value = serde_json::from_slice(&after)?;
    assert_eq!(after["state"]["columns"], 32);
    assert_eq!(after["state"]["rows"], 8);
    Ok(())
}

#[test]
fn separate_authenticated_stop_reaches_a_shell_with_backpressured_input() -> io::Result<()> {
    let server = TestServer::new()?;
    let session = [39; 16];
    let owner = [40; 16];
    let mut terminal = server.connect()?;
    terminal.set_write_timeout(Some(Duration::from_millis(250)))?;
    send(&mut terminal, 5, &[session, owner].concat())?;
    let ready = receive(&mut terminal)?;
    assert_eq!(ready.0, 0x81);
    let owner_state = control(owner, 1, true);
    assert_eq!(receive(&mut terminal)?, (0x84, owner_state.clone()));
    send(
        &mut terminal,
        3,
        b"stty raw -echo; printf 'blocked-ready\\r\\n'; sleep 30\n",
    )?;
    receive_output(&mut terminal, "blocked-ready\r\n")?;
    let block = vec![b'x'; 65_536];
    let error = (0..32)
        .try_for_each(|_| send(&mut terminal, 3, &block))
        .expect_err("test must apply input backpressure");
    assert!(matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    ));

    let mut viewer_stop = server.connect()?;
    send(
        &mut viewer_stop,
        14,
        &[&session[..], &[41; 16], &owner_state[..24]].concat(),
    )?;
    assert_eq!(
        receive(&mut viewer_stop)?,
        (
            0x83,
            b"Terminal control changed. Refresh and try again.".to_vec()
        ),
    );
    let mut stale_stop = server.connect()?;
    send(
        &mut stale_stop,
        14,
        &[&session[..], &owner, &control(owner, 0, true)[..24]].concat(),
    )?;
    assert_eq!(
        receive(&mut stale_stop)?,
        (
            0x83,
            b"Terminal control changed. Refresh and try again.".to_vec()
        ),
    );
    let mut stop = server.connect()?;
    send(
        &mut stop,
        14,
        &[&session[..], &owner, &owner_state[..24]].concat(),
    )?;
    assert_eq!(
        receive(&mut stop)?,
        (0x83, b"Terminal session stopped".to_vec())
    );
    assert_eq!(
        receive_frame(&mut terminal, 0x83)?,
        b"Terminal session stopped"
    );
    let pid = libc::pid_t::from_be_bytes(ready.1[4..].try_into().unwrap());
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "stopped shell was not reaped"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    Ok(())
}

#[test]
fn explicit_environment_clears_daemon_variables_and_preserves_terminal_defaults() -> io::Result<()>
{
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    let mut payload = [[42; 16], [43; 16]].concat();
    payload.extend(
        br#"{"shell":"/usr/bin/env","arguments":[],"environment":{"MYTERM_TEST_ENV":"expected"}}"#,
    );
    send(&mut client, 5, &payload)?;
    assert_eq!(receive(&mut client)?.0, 0x81);
    assert_eq!(receive(&mut client)?.0, 0x84);
    let mut output = Vec::new();
    loop {
        let (kind, payload) = receive(&mut client)?;
        if kind == 0x83 {
            assert!(String::from_utf8_lossy(&payload).contains("exit status: 0"));
            break;
        }
        assert_eq!(kind, 0x82);
        output.extend(payload);
    }
    let text = String::from_utf8(output).expect("environment output is ASCII");
    let mut lines: Vec<_> = text.lines().collect();
    lines.sort_unstable();
    assert_eq!(
        lines,
        [
            "MYTERM_TEST_ENV=expected",
            "SHELL=/usr/bin/env",
            "TERM=xterm-256color"
        ]
    );
    Ok(())
}

#[test]
fn resize_burst_preserves_the_controller_when_output_queue_is_full() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut client = server.connect()?;
    client.set_write_timeout(Some(Duration::from_secs(1)))?;
    send(&mut client, 5, &[[45; 16], [46; 16]].concat())?;
    assert_eq!(receive(&mut client)?.0, 0x81);
    assert_eq!(receive(&mut client)?.0, 0x84);
    send(
        &mut client,
        3,
        b"head -c 1048576 /dev/zero; printf 'prompt-after-stream\\n'\n",
    )?;
    thread::sleep(Duration::from_millis(200));

    let mut resizes = Vec::new();
    for columns in 100..500u16 {
        resizes.extend([4, 0, 0, 0, 4]);
        resizes.extend(columns.to_be_bytes());
        resizes.extend([0, 35]);
    }
    client.write_all(&resizes)?;
    send(
        &mut client,
        3,
        b"printf 'final-size=%s\\n' \"$(stty size)\"\n",
    )?;
    let marker = b"final-size=35 499\r\n";
    let mut output = Vec::new();
    let mut last_geometry = Vec::new();
    loop {
        let (kind, payload) = receive(&mut client)?;
        match kind {
            0x88 => last_geometry = payload,
            0x82 => {
                let start = output.len().saturating_sub(marker.len() - 1);
                output.extend(payload);
                assert!(output.len() <= 1024 * 1024 + 4096);
                if output[start..]
                    .windows(marker.len())
                    .any(|window| window == marker)
                {
                    break;
                }
            }
            _ => panic!(
                "Unexpected frame {kind:#x}: {:?}",
                String::from_utf8_lossy(&payload)
            ),
        }
    }
    assert_eq!(last_geometry, [1, 243, 0, 35]);
    Ok(())
}

#[test]
fn unread_query_flood_preserves_the_pty_process_and_server() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut owner = server.connect()?;
    let id = [48; 16];
    let client = [49; 16];
    let mut launch = [id, client].concat();
    let script = r#"
        /bin/stty raw -echo
        /usr/bin/awk 'BEGIN { for (i = 0; i < 90000; i++) printf "\033[c" }'
        printf 'query-flood-finished=%s\n' "$$"
        /bin/sleep 30
    "#;
    let options = serde_json::json!({
        "shell": "/bin/sh", "arguments": ["-c", script],
        "columns": 20, "rows": 6, "cellWidth": 9, "cellHeight": 16,
    });
    launch.extend(serde_json::to_vec(&options)?);
    send(&mut owner, 11, &launch)?;
    let (identity, sequence, _) = receive_checkpoint(&mut owner)?;
    send(&mut owner, 13, &sequence.to_be_bytes())?;
    let pid = u32::from_be_bytes(identity[4..8].try_into().unwrap());
    let marker = format!("query-flood-finished={pid}\n");
    assert_eq!(
        collect_live_body(&mut owner, marker.as_bytes(), 300_000)?,
        [b"\x1b[c".repeat(90_000), marker.into_bytes()].concat()
    );

    let mut stop = server.connect()?;
    let revision = control(client, 1, true);
    send(&mut stop, 14, &[&id[..], &client, &revision[..24]].concat())?;
    assert_eq!(
        receive(&mut stop)?,
        (0x83, b"Terminal session stopped".to_vec())
    );
    Ok(())
}

fn collect_live_body(socket: &mut UnixStream, marker: &[u8], limit: usize) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    loop {
        let (kind, bytes) = receive(socket)?;
        assert_eq!(kind, 0x82, "Unexpected frame {kind:#x}");
        output.extend(bytes);
        assert!(output.len() <= limit);
        if output.ends_with(marker) {
            return Ok(output);
        }
    }
}

#[test]
fn checkpoint_controller_throttles_output_during_import_without_stalling_other_sessions(
) -> io::Result<()> {
    let server = TestServer::new()?;
    let mut owner = server.connect()?;
    let id = [50; 16];
    let client = [51; 16];
    let mut launch = [id, client].concat();
    let options = serde_json::json!({
        "shell": "/bin/sh", "arguments": ["-c", "/usr/bin/head -c 1048576 /dev/zero; printf 'owner-saw-every-byte'"],
        "columns": 20, "rows": 6, "cellWidth": 9, "cellHeight": 16,
    });
    launch.extend(serde_json::to_vec(&options)?);
    send(&mut owner, 11, &launch)?;
    let (_, sequence, _) = receive_checkpoint(&mut owner)?;

    let mut other = server.connect()?;
    send(&mut other, 1, &[52; 16])?;
    assert_eq!(receive(&mut other)?.0, 0x81);
    thread::sleep(Duration::from_millis(250));
    send(&mut other, 3, b"printf 'unrelated-is-responsive\\n'\n")?;
    receive_output(&mut other, "unrelated-is-responsive\r\n")?;

    send(&mut owner, 13, &sequence.to_be_bytes())?;
    let marker = b"owner-saw-every-byte";
    let output = collect_live_body(&mut owner, marker, 1024 * 1024 + marker.len())?;
    assert_eq!(output.len(), 1024 * 1024 + marker.len());
    assert!(output[..1024 * 1024].iter().all(|&byte| byte == 0));
    let (kind, ended) = receive(&mut owner)?;
    assert_eq!(kind, 0x83);
    assert!(String::from_utf8_lossy(&ended).contains("exit status: 0"));
    Ok(())
}

#[test]
fn reply_budget_keeps_complete_replies_and_recovers_after_multipart_overflow() -> io::Result<()> {
    let mut terminal =
        myterm_terminal_state::TerminalState::new(myterm_terminal_state::Geometry {
            columns: 20,
            rows: 6,
            cell_width: 9,
            cell_height: 16,
        })?;
    // DSR replies with four bytes. XTVERSION starts with a two-byte DCS prefix
    // in a separate writer call, which must not escape when the remainder fails.
    let batch = terminal.advance_with_reply_budget(b"\x1b[5n\x1b[>q", 7)?;
    assert!(batch.overflow);
    assert_eq!(batch.bytes, b"\x1b[0n");
    let recovered = terminal.advance_with_reply_budget(b"\x1b[5n", 4)?;
    assert!(!recovered.overflow, "recovered data {:#x?}", recovered.bytes);
    assert_eq!(recovered.bytes, b"\x1b[0n");
    Ok(())
}

#[test]
fn out_of_band_stop_remains_available_during_checkpoint_output_backpressure() -> io::Result<()> {
    let server = TestServer::new()?;
    let mut owner = server.connect()?;
    let id = [53; 16];
    let client = [54; 16];
    let mut launch = [id, client].concat();
    let options = serde_json::json!({
        "shell": "/bin/sh", "arguments": ["-c", "exec /bin/cat /dev/zero"],
        "columns": 20, "rows": 6, "cellWidth": 9, "cellHeight": 16,
    });
    launch.extend(serde_json::to_vec(&options)?);
    send(&mut owner, 11, &launch)?;
    let (identity, _, _) = receive_checkpoint(&mut owner)?;

    // Hold the import acknowledgement and leave live bytes unread.
    thread::sleep(Duration::from_millis(250));
    let mut stop = server.connect()?;
    let revision = control(client, 1, true);
    send(&mut stop, 14, &[&id[..], &client, &revision[..24]].concat())?;
    assert_eq!(
        receive(&mut stop)?,
        (0x83, b"Terminal session stopped".to_vec())
    );
    let pid = libc::pid_t::from_be_bytes(identity[4..8].try_into().unwrap());
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "stopped shell was not reaped"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    Ok(())
}
