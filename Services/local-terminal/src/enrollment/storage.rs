use super::{Error, Result};
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;
use serde::{de::DeserializeOwned, Serialize};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;
use zeroize::Zeroizing;

pub(super) fn prepare_state_directory(directory: &Path) -> Result<()> {
    match DirBuilder::new().mode(0o700).create(directory) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    validate_state_directory(directory)
}

pub(super) fn validate_state_directory(directory: &Path) -> Result<()> {
    let info = fs::symlink_metadata(directory)?;
    if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        return Err(Error::UnsafeStateDirectory);
    }
    Ok(())
}

pub(super) fn read(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let info = file.metadata()?;
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        return Err(Error::UnsafeStateDirectory);
    }
    read_bounded(file, limit)
}

pub(super) fn read_bounded(input: impl Read, limit: u64) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(Error::InvalidArtifact);
    }
    Ok(bytes)
}

pub(super) fn read_json<T: DeserializeOwned>(path: &Path, limit: u64) -> Result<T> {
    serde_json::from_slice(&read(path, limit)?).map_err(|_| Error::InvalidArtifact)
}

pub(super) fn install_once(path: &Path, bytes: &[u8]) -> Result<()> {
    let directory = path.parent().ok_or(Error::UnsafeStateDirectory)?;
    let mut temporary = tempfile::NamedTempFile::new_in(directory)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist_noclobber(path)
        .map_err(|error| Error::Io(error.error))?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

pub(super) fn install_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| Error::InvalidArtifact)?;
    install_once(path, &bytes)
}

pub(super) fn signing_key(path: &Path, create: bool) -> Result<SigningKey> {
    fn load(path: &Path) -> Result<SigningKey> {
        let bytes = Zeroizing::new(read(path, 32)?);
        let seed: &[u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| Error::InvalidArtifact)?;
        Ok(SigningKey::from_bytes(seed))
    }

    match load(path) {
        Err(Error::Io(error)) if create && error.kind() == std::io::ErrorKind::NotFound => {
            let candidate = SigningKey::generate(&mut OsRng);
            match install_once(path, &Zeroizing::new(candidate.to_bytes())[..]) {
                Ok(()) => Ok(candidate),
                Err(Error::Io(error)) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    load(path)
                }
                Err(error) => Err(error),
            }
        }
        result => result,
    }
}
