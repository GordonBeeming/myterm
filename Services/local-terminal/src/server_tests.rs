use super::*;
use crate::tests::{receive, send, TestDirectory};

#[test]
fn an_expired_handshake_cannot_start_a_shell() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let mut server = Server::bind(&path, |_| Ok(()), Shell::for_test())?;
    let mut socket = UnixStream::connect(&path)?;
    server.step(100)?;
    server
        .connections
        .values_mut()
        .next()
        .unwrap()
        .handshake_deadline = Instant::now();
    send(&mut socket, START, &[20; 16])?;
    server.step(100)?;
    assert!(server.connections.is_empty());
    assert!(server.sessions.is_empty());

    let mut next = UnixStream::connect(&path)?;
    next.set_read_timeout(Some(Duration::from_secs(1)))?;
    send(&mut next, START, &[21; 16])?;
    server.step(100)?;
    server.step(100)?;
    assert_eq!(receive(&mut next)?.0, READY);
    Ok(())
}

#[test]
fn batched_resize_waits_for_earlier_input_to_reach_the_pty() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let mut server = Server::bind(&path, |_| Ok(()), Shell::for_test())?;
    let mut socket = UnixStream::connect(&path)?;
    socket.set_read_timeout(Some(Duration::from_secs(1)))?;
    send(&mut socket, START, &[22; 16])?;
    server.step(100)?;
    server.step(100)?;
    assert_eq!(receive(&mut socket)?.0, READY);

    send(&mut socket, INPUT, b"printf 'before resize'\r")?;
    send(&mut socket, RESIZE, &[0, 91, 0, 37])?;
    server.step(100)?;
    assert!(!server
        .sessions
        .values()
        .next()
        .unwrap()
        .pending_input
        .is_empty());
    assert_eq!(
        pty_size(&server.sessions.values().next().unwrap().pty)?,
        (80, 24)
    );

    let deadline = Instant::now() + Duration::from_secs(1);
    while pty_size(&server.sessions.values().next().unwrap().pty)? == (80, 24) {
        assert!(
            Instant::now() < deadline,
            "queued resize did not reach the PTY"
        );
        server.step(100)?;
    }
    assert!(server
        .sessions
        .values()
        .next()
        .unwrap()
        .pending_input
        .is_empty());
    assert_eq!(
        pty_size(&server.sessions.values().next().unwrap().pty)?,
        (91, 37)
    );
    Ok(())
}

fn pty_size(session: &Session) -> io::Result<(u16, u16)> {
    let mut size = std::mem::MaybeUninit::<libc::winsize>::uninit();
    check(unsafe {
        libc::ioctl(
            session.master.as_raw_fd(),
            libc::TIOCGWINSZ,
            size.as_mut_ptr(),
        )
    })?;
    let size = unsafe { size.assume_init() };
    Ok((size.ws_col, size.ws_row))
}

#[test]
fn listener_exhaustion_backs_off_without_stopping_a_live_terminal() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let mut server = Server::bind(&path, |_| Ok(()), Shell::for_test())?;
    // One PTY, one normal connection and one reserved command connection.
    server.descriptor_budget = 5;
    let mut client = UnixStream::connect(&path)?;
    client.set_read_timeout(Some(Duration::from_secs(1)))?;
    let session_id = [44; 16];
    send(&mut client, START, &session_id)?;
    server.step(100)?;
    server.step(100)?;
    let (kind, identity) = receive(&mut client)?;
    assert_eq!(kind, READY);
    assert!(server.can_admit(1, 2));
    assert!(!server.can_admit(2, 2));

    // Inject both kernel errors at the event-loop handler without changing
    // this process's descriptor limit for parallel fixture threads.
    server.accept_error(io::Error::from_raw_os_error(libc::EMFILE))?;
    server.accept_error(io::Error::from_raw_os_error(libc::ENFILE))?;
    assert!(server
        .accept_retry_at
        .is_some_and(|then| then > Instant::now()));

    let mut next = UnixStream::connect(&path)?;
    next.set_read_timeout(Some(Duration::from_secs(1)))?;
    send(&mut next, ATTACH, &session_id)?;
    server.step(0)?;
    assert_eq!(server.connections.len(), 1);
    assert_eq!(
        server.sessions[&session_id].pty.child.id().to_be_bytes(),
        identity[4..]
    );

    drop(client);
    server.accept_retry_at = Some(Instant::now());
    server.step(100)?;
    server.step(100)?;
    assert_eq!(receive(&mut next)?, (READY, identity));
    Ok(())
}
