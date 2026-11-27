use super::*;
use crate::tests::{receive, send, TestDirectory};

#[test]
fn an_expired_handshake_cannot_start_a_shell() -> io::Result<()> {
    let directory = TestDirectory::new()?;
    let path = directory.0.join("s");
    let mut server = Server::bind(&path, |_| Ok(()), Shell::for_test())?;
    let mut socket = UnixStream::connect(&path)?;
    server.step(100)?;
    server.connection.as_mut().unwrap().handshake_deadline = Instant::now();
    send(&mut socket, START, &[20; 16])?;
    server.step(100)?;
    assert!(server.connection.is_none());
    assert!(server.session.is_none());

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
    assert!(!server.connection.as_ref().unwrap().pending_input.is_empty());
    assert_eq!(pty_size(server.session.as_ref().unwrap())?, (80, 24));

    let deadline = Instant::now() + Duration::from_secs(1);
    while pty_size(server.session.as_ref().unwrap())? == (80, 24) {
        assert!(
            Instant::now() < deadline,
            "queued resize did not reach the PTY"
        );
        server.step(100)?;
    }
    assert!(server.connection.as_ref().unwrap().pending_input.is_empty());
    assert_eq!(pty_size(server.session.as_ref().unwrap())?, (91, 37));
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
