mod authentication;
mod checkpoint_stream;
mod server;
mod session;
mod socket;

use authentication::ClientAuthentication;
use server::Server;
use session::Shell;
use std::io;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(test)]
mod tests;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("MyTerm local terminal: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let first = args.next();
    let second = args.next();
    if first.as_deref() == Some(std::ffi::OsStr::new("enrollment")) {
        let operation = second.and_then(|operation| operation.into_string().ok());
        let directory = args.next();
        if let (Some(operation), Some(directory), None) = (operation, directory, args.next()) {
            return myterm_local_terminal::enrollment::command::run(
                &operation,
                &PathBuf::from(directory),
            )
            .map_err(io::Error::other);
        }
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Usage: myterm-local-terminal enrollment <operation> <state-directory>",
        ));
    }
    let path = match (first, second) {
        (Some(path), None) => PathBuf::from(path),
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Usage: myterm-local-terminal <socket-path>",
            ))
        }
    };
    let authentication = ClientAuthentication::new()?;
    let shell = Shell::for_user()?;
    install_shutdown_handler()?;
    Server::bind(
        &path,
        move |socket| authentication.authenticate(socket),
        shell,
    )?
    .run(|| STOPPING.load(Ordering::Relaxed))
}

static STOPPING: AtomicBool = AtomicBool::new(false);

extern "C" fn request_shutdown(_: libc::c_int) {
    // Defer PTY and child cleanup to the event loop.
    STOPPING.store(true, Ordering::Relaxed);
}

fn install_shutdown_handler() -> io::Result<()> {
    let mut action = libc::sigaction {
        sa_sigaction: request_shutdown as *const () as libc::sighandler_t,
        sa_mask: 0,
        sa_flags: 0,
    };
    session::check(unsafe { libc::sigemptyset(&mut action.sa_mask) })?;
    for signal in [libc::SIGTERM, libc::SIGINT] {
        session::check(unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) })?;
    }
    Ok(())
}
