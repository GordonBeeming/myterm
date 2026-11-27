use serde::Deserialize;
use std::collections::BTreeMap;
use std::ffi::CStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::{ffi::OsStrExt, process::CommandExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchOptions {
    shell: Option<PathBuf>,
    cwd: Option<PathBuf>,
    arguments: Option<Vec<String>>,
    columns: Option<u16>,
    rows: Option<u16>,
    environment: Option<BTreeMap<String, String>>,
}

impl LaunchOptions {
    pub fn parse(payload: &[u8]) -> io::Result<Self> {
        if payload.is_empty() {
            return Ok(Self::default());
        }
        let options: Self = serde_json::from_slice(payload).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid terminal launch settings",
            )
        })?;
        for path in [&options.shell, &options.cwd].into_iter().flatten() {
            if !path.is_absolute() || path.as_os_str().as_bytes().contains(&0) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Terminal shell and working directory must use absolute paths",
                ));
            }
        }
        if options.arguments.as_ref().is_some_and(|arguments| {
            arguments.len() > 128 || arguments.iter().any(|argument| argument.contains('\0'))
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid terminal shell arguments",
            ));
        }
        if options.environment.as_ref().is_some_and(|environment| {
            environment.len() > 256
                || environment.iter().any(|(key, value)| {
                    key.is_empty() || key.contains(['=', '\0']) || value.contains('\0')
                })
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid terminal environment",
            ));
        }
        options.geometry()?;
        Ok(options)
    }

    fn geometry(&self) -> io::Result<(u16, u16)> {
        match (self.columns, self.rows) {
            (None, None) => Ok((80, 24)),
            (Some(columns), Some(rows)) if columns > 0 && rows > 0 => Ok((columns, rows)),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Both initial terminal dimensions must be nonzero",
            )),
        }
    }
}

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

    pub fn start(&self, mut options: LaunchOptions) -> io::Result<Session> {
        let mut master_fd = -1;
        let mut slave_fd = -1;
        let (columns, rows) = options.geometry()?;
        let mut size = window_size(columns, rows);
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

        let executable = options.shell.as_ref().unwrap_or(&self.executable);
        let mut command = Command::new(executable);
        if let Some(mut environment) = options.environment.take() {
            if let Some(parent) = environment.get_mut("MYTERM_STARTUP_PARENT_PID") {
                *parent = std::process::id().to_string();
            }
            environment
                .entry("TERM".into())
                .or_insert_with(|| "xterm-256color".into());
            command.env_clear();
            if let Some(home) = &self.directory {
                command.env("HOME", home);
            }
            command.envs(environment);
        } else {
            command.env("TERM", "xterm-256color");
            if let Some(home) = &self.directory {
                command.env("HOME", home);
            }
        }
        if let Some(arguments) = options.arguments {
            command.args(arguments);
        } else {
            if self.login {
                command.arg("-l");
            }
            command.arg("-i");
        }
        if let Some(directory) = options.cwd.as_ref().or(self.directory.as_ref()) {
            command.current_dir(directory);
        }
        command
            .env("SHELL", executable)
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
        Ok(Session { master, child })
    }
}

pub struct Session {
    pub master: File,
    pub child: Child,
}

impl Session {
    pub fn begin_stop(self) -> StoppingShell {
        let Session { master, child } = self;
        // Closing the controlling PTY hangs up its foreground job, which can use
        // a different group from the shell. Signal only the shell's own group.
        drop(master);
        StoppingShell::new(child)
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

pub struct StoppingShell {
    child: Child,
    deadline: Instant,
    wait_error_logged: bool,
    kill_error_logged: bool,
    kill_sent: bool,
}

impl StoppingShell {
    fn new(mut child: Child) -> Self {
        let deadline = Instant::now() + Duration::from_millis(250);
        let result = child.try_wait().and_then(|status| {
            if status.is_some() {
                return Ok(());
            }
            signal_group(shell_group(&child)?, libc::SIGHUP)
        });
        if let Err(error) = result {
            eprintln!("Could not hang up local terminal shell: {error}");
        }
        Self {
            child,
            deadline,
            wait_error_logged: false,
            kill_error_logged: false,
            kill_sent: false,
        }
    }

    pub fn reaped(&mut self) -> bool {
        match self.child.try_wait() {
            Ok(Some(_)) => return true,
            // The kernel no longer has a waitable child. Its PID can be reused.
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => return true,
            Err(error) => {
                if !self.wait_error_logged {
                    eprintln!(
                        "Could not wait for local terminal shell {}: {error}",
                        self.child.id()
                    );
                    self.wait_error_logged = true;
                }
                return false;
            }
            Ok(None) => {}
        }
        if !self.kill_sent && Instant::now() >= self.deadline {
            // An unreaped child pins its PID so the signal cannot hit a reused group.
            let result = shell_group(&self.child)
                .and_then(|group| signal_group(group, libc::SIGKILL))
                .or_else(|_| self.child.kill());
            match result {
                Ok(()) => self.kill_sent = true,
                Err(error) => {
                    if !self.kill_error_logged {
                        eprintln!(
                            "Could not kill local terminal shell {}: {error}",
                            self.child.id()
                        );
                        self.kill_error_logged = true;
                    }
                    self.deadline = Instant::now() + Duration::from_secs(1);
                }
            }
        }
        false
    }
}

fn shell_group(child: &Child) -> io::Result<libc::pid_t> {
    libc::pid_t::try_from(child.id())
        .map_err(|_| io::Error::other("Invalid terminal shell process group"))
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
