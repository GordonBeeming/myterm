// Disposable native enrollment experiment. The private operator pipe is a trust fixture.
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, Read, Write},
    os::unix::{
        fs::OpenOptionsExt,
        io::{AsRawFd, FromRawFd},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};
type R<T> = Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn bytes(v: &Value) -> R<Vec<u8>> {
    serde_json::to_vec(v).map_err(err)
}
fn digest(v: &Value) -> R<String> {
    Ok(hex::encode(Sha256::digest(bytes(v)?)))
}
fn text<'a>(v: &'a Value, k: &str) -> R<&'a str> {
    v[k].as_str().ok_or_else(|| format!("missing {k}"))
}
fn signed(k: &SigningKey, p: Value) -> R<Value> {
    Ok(json!({"payload":p,"signature":hex::encode(k.sign(&bytes(&p)?).to_bytes())}))
}
fn verify(k: &str, envelope: &Value) -> R<Value> {
    let raw: [u8; 32] = hex::decode(k)
        .map_err(err)?
        .try_into()
        .map_err(|_| "key length")?;
    let key = VerifyingKey::from_bytes(&raw).map_err(err)?;
    let sig = Signature::from_slice(&hex::decode(text(envelope, "signature")?).map_err(err)?)
        .map_err(err)?;
    key.verify_strict(&bytes(&envelope["payload"])?, &sig)
        .map_err(|_| "signature".to_owned())?;
    Ok(envelope["payload"].clone())
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
struct Item {
    id: String,
    workspace: String,
    workspace_title: String,
    title: String,
    server: String,
    runtime: String,
}
#[derive(Clone, Serialize, Deserialize)]
struct Member {
    key: String,
    removed: bool,
}
#[derive(Clone, Serialize, Deserialize)]
struct Receipt {
    hash: String,
    result: Value,
}
#[derive(Clone, Serialize, Deserialize)]
struct State {
    account: String,
    epoch: u64,
    deleted: bool,
    revision: u64,
    members: BTreeMap<String, Member>,
    items: BTreeMap<String, Item>,
    tombstones: BTreeMap<String, Item>,
    operations: BTreeMap<String, Receipt>,
}
struct Authority {
    dir: PathBuf,
    state: State,
    key: SigningKey,
    _lock: File,
}
fn atomic(path: &Path, data: &[u8]) -> R<()> {
    atomic_with_fault(path, data, false)
}
fn atomic_with_fault(path: &Path, data: &[u8], fail_after_rename: bool) -> R<()> {
    let temp = path.with_extension("pending");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temp)
        .map_err(err)?;
    file.write_all(data).map_err(err)?;
    file.sync_all().map_err(err)?;
    fs::rename(&temp, path).map_err(err)?;
    // Once rename succeeds, returning an ordinary error would permit stale-memory writes.
    // Stop this writer on an uncertain directory commit; restart reloads the disk snapshot.
    if fail_after_rename {
        std::process::exit(73);
    }
    if let Err(e) = File::open(path.parent().ok_or("parent")?).and_then(|d| d.sync_all()) {
        eprintln!("uncertain commit after rename: {e}");
        std::process::exit(73);
    }
    Ok(())
}
impl Authority {
    fn load(dir: PathBuf) -> R<Self> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(dir.join("lock"))
            .map_err(err)?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("locked".into());
        }
        let key_path = dir.join("key");
        let seed: [u8; 32] = if key_path.exists() {
            fs::read(&key_path)
                .map_err(err)?
                .try_into()
                .map_err(|_| "seed")?
        } else {
            let k = SigningKey::generate(&mut OsRng);
            atomic(&key_path, &k.to_bytes())?;
            k.to_bytes()
        };
        let path = dir.join("state.json");
        let state = if path.exists() {
            serde_json::from_slice(&fs::read(path).map_err(err)?).map_err(err)?
        } else {
            let s = State {
                account: "account-a".into(),
                epoch: 1,
                deleted: false,
                revision: 0,
                members: BTreeMap::new(),
                items: BTreeMap::new(),
                tombstones: BTreeMap::new(),
                operations: BTreeMap::new(),
            };
            atomic(&path, &serde_json::to_vec(&s).map_err(err)?)?;
            s
        };
        Ok(Self {
            dir,
            state,
            key: SigningKey::from_bytes(&seed),
            _lock: lock,
        })
    }
    fn commit(&mut self, mut next: State, fault: &str) -> R<()> {
        next.revision += 1;
        let path = self.dir.join("state.json");
        // A backup failure prevents both membership and layout from being acknowledged.
        let backup = self
            .dir
            .join(format!("backup-{:020}.json", self.state.revision));
        if fault == "backup" {
            return Err("injected backup failure".into());
        }
        let original = fs::read(&path).map_err(err)?;
        atomic(&backup, &original)?;
        if fault == "before_commit" {
            std::process::exit(71);
        }
        atomic_with_fault(
            &path,
            &serde_json::to_vec(&next).map_err(err)?,
            fault == "after_rename_sync",
        )?;
        self.state = next;
        if fault == "after_commit" {
            std::process::exit(72);
        }
        let mut backups = fs::read_dir(&self.dir)
            .map_err(err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(err)?
            .into_iter()
            .map(|x| x.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("backup-") && n.ends_with(".json"))
            })
            .collect::<Vec<_>>();
        backups.sort();
        for p in backups.iter().take(backups.len().saturating_sub(5)) {
            fs::remove_file(p).map_err(err)?;
        }
        File::open(&self.dir)
            .map_err(err)?
            .sync_all()
            .map_err(err)?;
        Ok(())
    }
    fn handle(&mut self, req: Value) -> R<Value> {
        let op = text(&req, "op")?;
        let fault = req["fault"].as_str().unwrap_or("");
        match op {
            "status" => Ok(
                json!({"public_key":hex::encode(self.key.verifying_key().to_bytes()),"state":self.state}),
            ),
            "approve" => {
                if self.state.deleted {
                    return Err("account deleted".into());
                }
                let batch = verify(text(&req["batch"]["payload"], "key")?, &req["batch"])?;
                if batch["account"] != self.state.account || batch["epoch"] != self.state.epoch {
                    return Err("account/epoch".into());
                }
                let server = text(&batch, "server")?;
                if self.state.members.get(server).is_some_and(|m| m.removed) {
                    return Err("removed identity".into());
                }
                signed(
                    &self.key,
                    json!({"domain":"myterm-join-approval-prototype-v1","account":self.state.account,"epoch":self.state.epoch,"batch":digest(&req["batch"])?}),
                )
            }
            "join" => self.join(&req, fault),
            "remove" => {
                let mut next = self.state.clone();
                let server = text(&req, "server")?;
                let m = next.members.get_mut(server).ok_or("unknown member")?;
                m.removed = true;
                self.commit(next, fault)?;
                Ok(json!({"removed":server}))
            }
            "delete_account" => {
                let mut s = self.state.clone();
                s.deleted = true;
                s.epoch += 1;
                self.commit(s, fault)?;
                Ok(json!({"deleted":true}))
            }
            "delete_item" => {
                let mut next = self.state.clone();
                let id = text(&req, "id")?;
                let item = next.items.remove(id).ok_or("unknown item")?;
                next.tombstones.insert(id.into(), item);
                self.commit(next, fault)?;
                Ok(json!({"deleted":id,"runtime_action":"none"}))
            }
            _ => Err("unknown op".into()),
        }
    }
    fn join(&mut self, req: &Value, fault: &str) -> R<Value> {
        if self.state.deleted {
            return Err("account deleted".into());
        }
        let batch = &req["batch"];
        let p = verify(text(&batch["payload"], "key")?, batch)?;
        if p["domain"] != "myterm-local-batch-prototype-v1"
            || p["account"] != self.state.account
            || p["epoch"] != self.state.epoch
        {
            return Err("batch context".into());
        }
        let server = text(&p, "server")?;
        let key = text(&p, "key")?;
        let operation = text(&p, "operation")?;
        let member = self.state.members.get(server);
        if let Some(m) = member {
            if m.removed || m.key != key {
                return Err("membership denied".into());
            }
        }
        let hash = digest(batch)?;
        let operation_key = format!("{}:{server}{operation}", server.len());
        if let Some(receipt) = self.state.operations.get(&operation_key) {
            return if receipt.hash == hash {
                Ok(receipt.result.clone())
            } else {
                Err("operation conflict".into())
            };
        }
        let mode = text(&p, "mode")?;
        match (member, mode) {
            (None, "first") => {
                let approval = verify(
                    &hex::encode(self.key.verifying_key().to_bytes()),
                    &req["approval"],
                )?;
                if approval
                    != json!({"domain":"myterm-join-approval-prototype-v1","account":self.state.account,"epoch":self.state.epoch,"batch":hash})
                {
                    return Err("approval binding".into());
                }
            }
            (Some(_), "return") => {}
            _ => return Err("membership mode".into()),
        }
        let items: Vec<Item> = serde_json::from_value(p["items"].clone()).map_err(err)?;
        if items.len() > 128 {
            return Err("batch size".into());
        }
        let mut unique = BTreeMap::new();
        let mut workspace_names = BTreeMap::new();
        let mut next = self.state.clone();
        let mut skipped = Vec::new();
        for item in items {
            if let Some(title) =
                workspace_names.insert(item.workspace.clone(), item.workspace_title.clone())
            {
                if title != item.workspace_title {
                    return Err("workspace title conflict".into());
                }
            }
            for existing in self
                .state
                .items
                .values()
                .filter(|e| e.workspace == item.workspace)
            {
                if mode == "first" {
                    return Err("workspace identity conflict".into());
                }
                if existing.workspace_title != item.workspace_title {
                    return Err("workspace title conflict".into());
                }
            }
            if item.server != server
                || item.id.is_empty()
                || item.workspace.is_empty()
                || item.runtime.is_empty()
            {
                return Err("item binding".into());
            }
            if unique.insert(item.id.clone(), ()).is_some() {
                return Err("duplicate identity".into());
            }
            if let Some(deleted) = next.tombstones.get(&item.id) {
                if deleted.server != item.server || deleted.runtime != item.runtime {
                    return Err("tombstone identity conflict".into());
                }
                skipped.push(item.id);
                continue;
            }
            if let Some(existing) = next.items.get(&item.id) {
                if existing != &item {
                    return Err("identity conflict".into());
                }
            }
            next.items.insert(item.id.clone(), item);
        }
        next.members.insert(
            server.into(),
            Member {
                key: key.into(),
                removed: false,
            },
        );
        let result = json!({"joined":server,"mode":mode,"skipped_deleted":skipped,"revision":next.revision+1});
        next.operations.insert(
            operation_key,
            Receipt {
                hash,
                result: result.clone(),
            },
        );
        self.commit(next, fault)?;
        Ok(result)
    }
}
struct Runtime {
    key: SigningKey,
    server: String,
    child: Child,
    master: Option<File>,
}
impl Runtime {
    fn start(server: String) -> R<Self> {
        let mut master = -1;
        let mut slave = -1;
        if unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } != 0
        {
            return Err(err(io::Error::last_os_error()));
        }
        let master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        // Only the shell inherits the slave; the server keeps the PTY master across joins.
        if unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(err(io::Error::last_os_error()));
        }
        let mut command = Command::new("/bin/sh");
        command
            .arg("-i")
            .env("PS1", "")
            .stdin(Stdio::from(slave.try_clone().map_err(err)?))
            .stdout(Stdio::from(slave.try_clone().map_err(err)?))
            .stderr(Stdio::from(slave));
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY.into(), 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().map_err(err)?;
        Ok(Self {
            key: SigningKey::generate(&mut OsRng),
            server,
            child,
            master: Some(master),
        })
    }
    fn handle(&mut self, req: Value) -> R<Value> {
        match text(&req, "op")? {
            "batch" => signed(
                &self.key,
                json!({"domain":"myterm-local-batch-prototype-v1","account":req["account"],"epoch":req["epoch"],"operation":req["operation"],"mode":req["mode"],"server":self.server,"key":hex::encode(self.key.verifying_key().to_bytes()),"items":req["items"]}),
            ),
            "identity" => Ok(
                json!({"server":self.server,"key":hex::encode(self.key.verifying_key().to_bytes()),"pid":self.child.id()}),
            ),
            "echo" => {
                let master = self.master.as_mut().ok_or("PTY closed")?;
                let marker = text(&req, "marker")?;
                if marker.is_empty() || !marker.bytes().all(|b| b.is_ascii_uppercase()) {
                    return Err("marker".into());
                }
                // Octal escapes prevent PTY input echo from satisfying the output assertion.
                let encoded = marker
                    .bytes()
                    .map(|b| format!("\\{:03o}", b))
                    .collect::<String>();
                master
                    .write_all(format!("printf '{encoded}:%s\\n' \"$$\"\n").as_bytes())
                    .map_err(err)?;
                let target = format!("{marker}:{}", self.child.id());
                let mut output = Vec::new();
                let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
                loop {
                    let mut poll = libc::pollfd {
                        fd: master.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    };
                    let n = unsafe { libc::poll(&mut poll, 1, 100) };
                    if n < 0 {
                        return Err(err(io::Error::last_os_error()));
                    }
                    if n > 0 {
                        let mut b = [0; 4096];
                        let count = master.read(&mut b).map_err(err)?;
                        if count == 0 {
                            return Err("PTY closed".into());
                        }
                        output.extend_from_slice(&b[..count]);
                    }
                    if String::from_utf8_lossy(&output).contains(&target) {
                        return Ok(
                            json!({"pid":self.child.id(),"marker":marker,"observed":target}),
                        );
                    }
                    if std::time::Instant::now() > until || output.len() > 65536 {
                        return Err("PTY deadline".into());
                    }
                }
            }
            _ => Err("unknown runtime op".into()),
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        // Release the PTY before reaping so an unread terminal cannot hold teardown open.
        drop(self.master.take());
        if let Err(e) = self.child.kill() {
            eprintln!("shell cleanup: {e}");
        }
        if let Err(e) = self.child.wait() {
            eprintln!("shell wait: {e}");
        }
    }
}
fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    let setup: R<Box<dyn FnMut(Value) -> R<Value>>> = match args.get(1).map(String::as_str) {
        Some("authority") => args
            .get(2)
            .ok_or("directory".into())
            .and_then(|d| Authority::load(d.into()))
            .map(|mut a| Box::new(move |v| a.handle(v)) as Box<dyn FnMut(Value) -> R<Value>>),
        Some("runtime") => Runtime::start(
            args.get(2)
                .cloned()
                .unwrap_or_else(|| "server-local".into()),
        )
        .map(|mut r| Box::new(move |v| r.handle(v)) as Box<dyn FnMut(Value) -> R<Value>>),
        _ => Err("role".into()),
    };
    let mut handler = match setup {
        Ok(h) => h,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };
    for line in io::stdin().lock().lines() {
        let result = line
            .map_err(err)
            .and_then(|s| {
                if s.len() > 262144 {
                    Err("frame size".into())
                } else {
                    serde_json::from_str(&s).map_err(err)
                }
            })
            .and_then(&mut handler);
        let response = match result {
            Ok(v) => json!({"ok":true,"value":v}),
            Err(e) => json!({"ok":false,"error":e}),
        };
        if writeln!(io::stdout(), "{response}")
            .and_then(|_| io::stdout().flush())
            .is_err()
        {
            break;
        }
    }
}
