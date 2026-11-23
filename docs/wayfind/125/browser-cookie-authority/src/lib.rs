//! Wayfinding prototype. The harness supplies authenticated client scopes and fixture cookie values.

use chacha20poly1305::{
    aead::{Aead, AeadCore, OsRng, Payload},
    KeyInit, XChaCha20Poly1305, XNonce,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Scope {
    pub account: String,
    pub server: String,
    pub profile: String,
}

pub struct ApprovedClientScope(pub Scope);

#[derive(Debug, PartialEq, Eq)]
pub enum Rejection {
    ForeignScope,
    SharingDisabled,
    StaleSharingPolicy,
    Conflict,
    InvalidBatch,
    VersionExhausted,
    UnreadableState,
    StorageFailure,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub version: u64,
    pub value: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct State {
    epoch: u64,
    version: u64,
    opted_out: BTreeSet<String>,
    entries: BTreeMap<String, Entry>,
}

pub struct Snapshot {
    pub epoch: u64,
    pub entries: BTreeMap<String, Entry>,
}

pub struct Change {
    pub cookie_key: String,
    pub previous_version: Option<u64>,
    pub value: Option<String>,
}

pub struct Authority {
    scope: Scope,
    associated_data: Vec<u8>,
    path: PathBuf,
    cipher: XChaCha20Poly1305,
    state: State,
}

impl Authority {
    pub fn create(scope: Scope, path: &Path, key: &[u8; 32]) -> Result<Self, Rejection> {
        let authority = Self::new(scope, path, key)?;
        authority.write_state(&authority.state, false)?;
        Ok(authority)
    }

    pub fn open(scope: Scope, path: &Path, key: &[u8; 32]) -> Result<Self, Rejection> {
        let mut authority = Self::new(scope, path, key)?;
        let bytes = fs::read(path).map_err(|_| Rejection::UnreadableState)?;
        if bytes.len() < 24 {
            return Err(Rejection::UnreadableState);
        }
        let (nonce, ciphertext) = bytes.split_at(24);
        let plaintext = authority
            .cipher
            .decrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: &authority.associated_data,
                },
            )
            .map_err(|_| Rejection::UnreadableState)?;
        authority.state =
            serde_json::from_slice(&plaintext).map_err(|_| Rejection::UnreadableState)?;
        Ok(authority)
    }

    fn new(scope: Scope, path: &Path, key: &[u8; 32]) -> Result<Self, Rejection> {
        let associated_data = serde_json::to_vec(&("myterm-cookie-fixture-v1", &scope))
            .map_err(|_| Rejection::UnreadableState)?;
        Ok(Self {
            scope,
            associated_data,
            path: path.to_owned(),
            cipher: XChaCha20Poly1305::new(key.into()),
            state: State::default(),
        })
    }

    fn check_sharing(&self, client: &ApprovedClientScope) -> Result<(), Rejection> {
        if client.0 != self.scope {
            return Err(Rejection::ForeignScope);
        }
        if !self.state.opted_out.is_empty() {
            return Err(Rejection::SharingDisabled);
        }
        Ok(())
    }

    pub fn snapshot(&self, client: &ApprovedClientScope) -> Result<Snapshot, Rejection> {
        self.check_sharing(client)?;
        Ok(Snapshot {
            epoch: self.state.epoch,
            entries: self.state.entries.clone(),
        })
    }

    pub fn set_workspace_opt_out(
        &mut self,
        workspace: &str,
        opted_out: bool,
    ) -> Result<(), Rejection> {
        let mut next = self.state.clone();
        let changed = if opted_out {
            next.opted_out.insert(workspace.into())
        } else {
            next.opted_out.remove(workspace)
        };
        if !changed {
            return Ok(());
        }
        if next.opted_out.is_empty() != self.state.opted_out.is_empty() {
            next.epoch = self
                .state
                .epoch
                .checked_add(1)
                .ok_or(Rejection::VersionExhausted)?;
        }
        self.commit(next)
    }

    pub fn apply(
        &mut self,
        client: &ApprovedClientScope,
        epoch: u64,
        changes: Vec<Change>,
    ) -> Result<(), Rejection> {
        self.check_sharing(client)?;
        if epoch != self.state.epoch {
            return Err(Rejection::StaleSharingPolicy);
        }
        if changes.is_empty() {
            return Ok(());
        }
        let mut seen = BTreeSet::new();
        for change in &changes {
            if !seen.insert(&change.cookie_key) || change.cookie_key.is_empty() {
                return Err(Rejection::InvalidBatch);
            }
            let current_version = self
                .state
                .entries
                .get(&change.cookie_key)
                .map(|entry| entry.version);
            if current_version != change.previous_version {
                return Err(Rejection::Conflict);
            }
        }
        let mut next = self.state.clone();
        for change in changes {
            next.version = next
                .version
                .checked_add(1)
                .ok_or(Rejection::VersionExhausted)?;
            // A deletion keeps its version so a stale client's write cannot recreate the cookie.
            next.entries.insert(
                change.cookie_key,
                Entry {
                    version: next.version,
                    value: change.value,
                },
            );
        }
        self.commit(next)
    }

    fn commit(&mut self, next: State) -> Result<(), Rejection> {
        self.write_state(&next, true)?;
        self.state = next;
        Ok(())
    }

    fn write_state(&self, next: &State, replace: bool) -> Result<(), Rejection> {
        let plaintext = serde_json::to_vec(next).map_err(|_| Rejection::StorageFailure)?;
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let sealed = self
            .cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: &plaintext,
                    aad: &self.associated_data,
                },
            )
            .map_err(|_| Rejection::StorageFailure)?;
        let parent = self.path.parent().ok_or(Rejection::StorageFailure)?;
        let mut pending = NamedTempFile::new_in(parent).map_err(|_| Rejection::StorageFailure)?;
        pending
            .write_all(&nonce)
            .map_err(|_| Rejection::StorageFailure)?;
        pending
            .write_all(&sealed)
            .map_err(|_| Rejection::StorageFailure)?;
        pending
            .as_file()
            .sync_all()
            .map_err(|_| Rejection::StorageFailure)?;
        if replace {
            pending
                .persist(&self.path)
                .map_err(|_| Rejection::StorageFailure)?;
        } else {
            pending
                .persist_noclobber(&self.path)
                .map_err(|_| Rejection::StorageFailure)?;
        }
        Ok(())
    }
}
