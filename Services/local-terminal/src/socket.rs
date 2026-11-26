use crate::session::check;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::ptr;

pub struct Socket {
    path: PathBuf,
    metadata: Metadata,
    pub listener: UnixListener,
    _lock: File,
}

impl Socket {
    pub fn bind(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() || path.file_name().is_none() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "An absolute local terminal socket path is required",
            ));
        }
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("Local terminal socket directory is missing"))?;
        let parent = fs::symlink_metadata(parent)?;
        let uid = unsafe { libc::geteuid() };
        if !parent.is_dir() || parent.uid() != uid || parent.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Local terminal socket directory must be private and owned by this user",
            ));
        }

        // Keep this lock inode until the server drops the socket. Unlinking the lock would
        // allow two launchers to flock different inodes while replacing the same socket.
        let mut lock_path = path.as_os_str().to_os_string();
        lock_path.push(".lock");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(lock_path)?;
        let metadata = lock.metadata()?;
        if !metadata.is_file() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Local terminal socket lock is not a private file owned by this user",
            ));
        }
        check(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) })?;

        clear_stale_socket(path, uid)?;
        let listener = UnixListener::bind(path)?;
        let socket = Self {
            path: path.to_owned(),
            metadata: fs::symlink_metadata(path)?,
            listener,
            _lock: lock,
        };
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        socket.listener.set_nonblocking(true)?;
        Ok(socket)
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        match fs::symlink_metadata(&self.path) {
            Ok(current) if same_inode(&current, &self.metadata) => {
                if let Err(error) = fs::remove_file(&self.path) {
                    eprintln!("Could not remove local terminal socket: {error}");
                }
            }
            Ok(_) => eprintln!("Local terminal socket was replaced while the server was running"),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                eprintln!("Could not inspect local terminal socket during cleanup: {error}")
            }
        }
    }
}

fn clear_stale_socket(path: &Path, uid: u32) -> io::Result<()> {
    let existing = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !existing.file_type().is_socket() || existing.uid() != uid {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "Local terminal socket path belongs to another file",
        ));
    }
    match UnixStream::connect(path) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "Local terminal socket is already listening",
        )),
        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
            if !same_inode(&existing, &fs::symlink_metadata(path)?) {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "Local terminal socket changed during startup",
                ));
            }
            fs::remove_file(path)
        }
        Err(error) => Err(error),
    }
}

fn same_inode(first: &Metadata, second: &Metadata) -> bool {
    first.dev() == second.dev() && first.ino() == second.ino()
}

pub struct PeerEvents(OwnedFd);

impl PeerEvents {
    pub fn new(stream: &UnixStream) -> io::Result<Self> {
        let descriptor = unsafe { libc::kqueue() };
        check(descriptor)?;
        let queue = unsafe { OwnedFd::from_raw_fd(descriptor) };
        check(unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) })?;
        let source = libc::kevent {
            ident: stream.as_raw_fd() as libc::uintptr_t,
            filter: libc::EVFILT_READ,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: 0,
            data: 0,
            udata: ptr::null_mut(),
        };
        check(unsafe { libc::kevent(descriptor, &source, 1, ptr::null_mut(), 0, ptr::null()) })?;
        Ok(Self(queue))
    }

    pub fn closed(&self) -> io::Result<bool> {
        // Darwin poll can hide a disconnect when reads are paused. EV_EOF also
        // reports it when the socket still contains bytes from the closed peer.
        let ready_now = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        let mut event = std::mem::MaybeUninit::<libc::kevent>::uninit();
        let count = unsafe {
            libc::kevent(
                self.0.as_raw_fd(),
                ptr::null(),
                0,
                event.as_mut_ptr(),
                1,
                &ready_now,
            )
        };
        if count == -1 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(error)
            };
        }
        if count == 0 {
            return Ok(false);
        }
        let event = unsafe { event.assume_init() };
        if event.flags & libc::EV_ERROR != 0 {
            return Err(io::Error::from_raw_os_error(event.data as i32));
        }
        Ok(event.flags & libc::EV_EOF != 0)
    }
}
