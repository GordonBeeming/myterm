use super::*;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicU32, Ordering},
    Arc,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> io::Result<Self> {
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

fn send(socket: &mut UnixStream, kind: u8, payload: &[u8]) -> io::Result<()> {
    socket.write_all(&[kind])?;
    socket.write_all(&(payload.len() as u32).to_be_bytes())?;
    socket.write_all(payload)
}

fn receive(socket: &mut UnixStream) -> io::Result<(u8, Vec<u8>)> {
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
    let stale = std::os::unix::net::UnixListener::bind(&path)?;
    drop(stale);
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
