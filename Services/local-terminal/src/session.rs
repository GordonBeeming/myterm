use std::ffi::CStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::{ffi::OsStrExt, process::CommandExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub struct Shell {
    executable: PathBuf,
    directory: Option<PathBuf>,
    login: bool,
}

impl Shell {
    pub fn for_user() -> io::Result<Self> {
        let uid = unsafe { libc::geteuid() };
        let mut buffer = vec![0; 16_384];
        let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let status = unsafe {
            libc::getpwuid_r(
                uid,
                entry.as_mut_ptr(),
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut result,
            )
        };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status));
        }
        if result.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Local terminal account is missing",
            ));
        }
        let entry = unsafe { entry.assume_init() };
        let mut executable = password_path(entry.pw_shell)?;
        if executable.as_os_str().is_empty() {
            executable = "/bin/sh".into();
        }
        let directory = password_path(entry.pw_dir)?;
        if !executable.is_absolute() || !directory.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Login shell and home directory must use absolute paths",
            ));
        }
        Ok(Self {
            executable,
            directory: Some(directory),
            login: true,
        })
    }

    #[cfg(test)]
    pub fn for_test() -> Self {
        Self {
            executable: "/bin/sh".into(),
            directory: None,
            login: false,
        }
    }

    pub fn start(&self, id: [u8; 16]) -> io::Result<Session> {
        let mut master_fd = -1;
        let mut slave_fd = -1;
        let mut size = window_size(80, 24);
        // openpty creates both descriptors on success. Ownership moves to the Files below.
        if unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        } == -1
        {
            return Err(io::Error::last_os_error());
        }
        let master = unsafe { File::from_raw_fd(master_fd) };
        let slave = unsafe { File::from_raw_fd(slave_fd) };
        check(unsafe { libc::fcntl(master_fd, libc::F_SETFD, libc::FD_CLOEXEC) })?;
        check(unsafe { libc::fcntl(slave_fd, libc::F_SETFD, libc::FD_CLOEXEC) })?;
        check(unsafe { libc::fcntl(master_fd, libc::F_SETFL, libc::O_NONBLOCK) })?;

        let mut command = Command::new(&self.executable);
        if self.login {
            command.arg("-l");
        }
        if let Some(directory) = &self.directory {
            command.current_dir(directory).env("HOME", directory);
        }
        command
            .arg("-i")
            .env("TERM", "xterm-256color")
            .env("SHELL", &self.executable)
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        // The child needs its own session and controlling terminal for shell job control.
        // Between fork and exec this closure uses only async-signal-safe system operations.
        unsafe {
            command.pre_exec(|| {
                check(libc::setsid())?;
                check(libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY.into(), 0))?;
                Ok(())
            });
        }
        let child = command.spawn()?;
        Ok(Session { id, master, child })
    }
}

pub struct Session {
    pub id: [u8; 16],
    pub master: File,
    pub child: Child,
}

impl Session {
    pub fn stop(self) -> io::Result<()> {
        let Session {
            master, mut child, ..
        } = self;
        // Closing the controlling PTY hangs up its foreground job, which can use
        // a different group from the shell. Signal only the shell's own group.
        drop(master);
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        let group = libc::pid_t::try_from(child.id())
            .map_err(|_| io::Error::other("Invalid terminal shell process group"))?;
        let hangup = signal_group(group, libc::SIGHUP);
        let deadline = Instant::now() + Duration::from_millis(250);
        loop {
            if child.try_wait()?.is_some() {
                return hangup;
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // The child remains unreaped, so its PID cannot be reused for a new group.
        signal_group(group, libc::SIGKILL)?;
        child.wait()?;
        hangup
    }

    pub fn resize(&self, columns: u16, rows: u16) -> io::Result<()> {
        if columns == 0 || rows == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Terminal dimensions must be nonzero",
            ));
        }
        let size = window_size(columns, rows);
        check(unsafe { libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &size) })
    }
}

fn signal_group(group: libc::pid_t, signal: libc::c_int) -> io::Result<()> {
    match check(unsafe { libc::kill(-group, signal) }) {
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(()),
        result => result,
    }
}

fn password_path(value: *const libc::c_char) -> io::Result<PathBuf> {
    if value.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Incomplete local terminal account",
        ));
    }
    // The caller keeps the getpwuid_r buffer alive until this path has been copied.
    let path = unsafe { CStr::from_ptr(value) }.to_bytes();
    Ok(std::ffi::OsStr::from_bytes(path).into())
}

fn window_size(columns: u16, rows: u16) -> libc::winsize {
    libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

pub fn check(result: libc::c_int) -> io::Result<()> {
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
