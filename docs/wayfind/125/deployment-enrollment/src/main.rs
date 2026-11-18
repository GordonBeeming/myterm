//! Disposable native protocol probe. Bootstrap pins and operator commands use trusted pipes.
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    os::fd::AsRawFd,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, String>;
const ACCOUNT: &str = "disposable-personal-account";
const LIMIT: u64 = 262144;
// Prototype-only bounds reserve ample journal framing space for revocation and tombstones.
const CREDENTIAL_CAP: usize = 16;
const IDENTITY_CAP: usize = 64;
fn err<T>(s: &str) -> Result<T> {
    Err(s.into())
}
fn bytes(v: &Value) -> Result<Vec<u8>> {
    serde_json::to_vec(v).map_err(|e| e.to_string())
}
fn digest(v: &Value) -> Result<String> {
    Ok(hex::encode(Sha256::digest(bytes(v)?)))
}
fn field<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("field:{k}"))
}
fn num(v: &Value, k: &str) -> Result<u64> {
    v.get(k)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("field:{k}"))
}
fn pk(key: &SigningKey) -> String {
    hex::encode(key.verifying_key().to_bytes())
}
fn key(s: &str) -> Result<VerifyingKey> {
    let b: [u8; 32] = hex::decode(s)
        .map_err(|_| "key")?
        .try_into()
        .map_err(|_| "key")?;
    if hex::encode(b) != s {
        return err("noncanonical-key");
    }
    VerifyingKey::from_bytes(&b).map_err(|_| "key".into())
}
fn sign(key: &SigningKey, payload: Value) -> Result<Value> {
    let signature = hex::encode(key.sign(&bytes(&payload)?).to_bytes());
    Ok(json!({"payload":payload,"signature":signature}))
}
fn verify<'a>(signed: &'a Value, public: &str, purpose: &str) -> Result<&'a Value> {
    if signed.as_object().map(|m| m.len()) != Some(2) {
        return err("signed-schema");
    }
    let payload = signed.get("payload").ok_or("payload")?;
    if field(payload, "account")? != ACCOUNT || field(payload, "purpose")? != purpose {
        return err("binding");
    }
    let signature =
        Signature::from_slice(&hex::decode(field(signed, "signature")?).map_err(|_| "signature")?)
            .map_err(|_| "signature")?;
    key(public)?
        .verify_strict(&bytes(payload)?, &signature)
        .map_err(|_| "signature")?;
    Ok(payload)
}
fn wall() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|e| e.to_string())
}
fn output(v: &Value) -> Result<()> {
    let mut o = std::io::stdout().lock();
    writeln!(o, "{v}")
        .and_then(|_| o.flush())
        .map_err(|e| e.to_string())
}
fn read_json<R: BufRead>(r: &mut R) -> Result<Option<Value>> {
    let mut line = String::new();
    let n = r
        .take(LIMIT + 1)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    if n == 0 {
        return Ok(None);
    }
    if n as u64 > LIMIT || !line.ends_with('\n') {
        return err("frame-limit-or-eof");
    }
    serde_json::from_str(&line)
        .map(Some)
        .map_err(|_| "json".into())
}
fn response(result: Result<Value>) -> Value {
    match result {
        Ok(v) => json!({"ok":true,"value":v}),
        Err(e) => json!({"ok":false,"error":e}),
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct State {
    credentials: BTreeMap<String, Value>,
    revoked: BTreeSet<String>,
    removed: BTreeSet<String>,
    members: BTreeMap<String, Value>,
    allocations: BTreeMap<String, Value>,
}
struct Authority {
    key: SigningKey,
    state: State,
    journal: File,
    sequence: u64,
    previous: String,
    fixture: bool,
    fixture_now: Option<u64>,
    base_wall: u64,
    base_mono: Instant,
    crash: bool,
    crash_before: bool,
}
impl Authority {
    fn now(&self) -> Result<u64> {
        if let Some(t) = self.fixture_now {
            return Ok(t);
        }
        // A wall-clock rollback during this process cannot extend credential validity.
        Ok(wall()?.max(
            self.base_wall
                .saturating_add(self.base_mono.elapsed().as_secs()),
        ))
    }
    fn snapshot(&self) -> Result<Value> {
        sign(
            &self.key,
            json!({"purpose":"directory","account":ACCOUNT,"sequence":self.sequence,"head":self.previous,"state":self.state}),
        )
    }
    fn commit(&mut self, next: State) -> Result<Value> {
        let seq = self.sequence.checked_add(1).ok_or("sequence-overflow")?;
        let event = sign(
            &self.key,
            json!({"purpose":"journal","account":ACCOUNT,"sequence":seq,"previous":self.previous,"state":next}),
        )?;
        let line = bytes(&event)?;
        if line.len() as u64 >= LIMIT {
            return err("journal-limit");
        }
        if self.crash_before {
            std::process::exit(75);
        }
        // An uncertain append must terminate the authority; continuing could acknowledge a fork.
        if self
            .journal
            .write_all(&line)
            .and_then(|_| self.journal.write_all(b"\n"))
            .and_then(|_| self.journal.sync_all())
            .is_err()
        {
            std::process::exit(73);
        }
        self.previous = digest(&event)?;
        self.sequence = seq;
        self.state = next;
        if self.crash {
            std::process::exit(74);
        }
        self.snapshot()
    }
    fn room_for(&self, public: &str) -> Result<()> {
        if !self.state.members.contains_key(public)
            && self.state.members.len() + self.state.removed.len() >= IDENTITY_CAP
        {
            return err("identity-cap");
        }
        Ok(())
    }
    fn command(&mut self, v: &Value, operator: bool) -> Result<Value> {
        let op = field(v, "op")?;
        if operator {
            match op {
                "clock" => {
                    if !self.fixture {
                        return err("fixture-disabled");
                    }
                    self.fixture_now = v.get("now").and_then(Value::as_u64);
                    return Ok(json!(self.now()?));
                }
                "crash-before-write" => {
                    self.crash_before = true;
                    return Ok(json!(true));
                }
                "crash-after-sync" => {
                    self.crash = true;
                    return Ok(json!(true));
                }
                "issue" => {
                    let id = field(v, "id")?;
                    let mode = field(v, "mode")?;
                    let holder = field(v, "holder")?;
                    let creator = v.get("creator").and_then(Value::as_str).unwrap_or("");
                    if !creator.is_empty() && !self.state.members.contains_key(creator) {
                        return err("creator-not-current");
                    }
                    if id.is_empty() || id.len() > 128 || self.state.credentials.contains_key(id) {
                        return err("credential-id");
                    }
                    if self.state.credentials.len() >= CREDENTIAL_CAP {
                        return err("credential-cap");
                    }
                    key(holder)?;
                    if !["single-use", "reusable"].contains(&mode) {
                        return err("mode");
                    }
                    let ttl = v
                        .get("ttl")
                        .map(|_| num(v, "ttl"))
                        .transpose()?
                        .unwrap_or(if mode == "reusable" { 2592000 } else { 1800 });
                    if ttl == 0 || (mode == "single-use" && ttl > 1800) {
                        return err("ttl");
                    }
                    let now = self.now()?;
                    let expiry = now
                        .checked_add(ttl)
                        .filter(|n| *n <= i64::MAX as u64)
                        .ok_or("expiry")?;
                    let cert = sign(
                        &self.key,
                        json!({"purpose":"credential","account":ACCOUNT,"id":id,"mode":mode,"holder":holder,"issued":now,"expires":expiry,"role":"server","owner":"account","creator":creator}),
                    )?;
                    let mut s = self.state.clone();
                    s.credentials.insert(id.into(), cert.clone());
                    self.commit(s)?;
                    return Ok(cert);
                }
                "revoke" => {
                    let id = field(v, "id")?;
                    if !self.state.credentials.contains_key(id) {
                        return err("unknown-credential");
                    }
                    let mut s = self.state.clone();
                    s.revoked.insert(id.into());
                    return self.commit(s);
                }
                "remove" => {
                    let public = field(v, "public")?;
                    key(public)?;
                    self.room_for(public)?;
                    let mut s = self.state.clone();
                    s.removed.insert(public.into());
                    s.members.remove(public);
                    return self.commit(s);
                }
                "fresh-approve" => {
                    let request = v.get("request").ok_or("request")?;
                    let payload = verify_subject(request)?;
                    let public = field(payload, "public")?;
                    if self.state.removed.contains(public) {
                        return err("removed-identity");
                    }
                    if !self
                        .state
                        .credentials
                        .contains_key(field(payload, "credential")?)
                    {
                        return err("unknown-credential");
                    }
                    if let Some(old) = self.state.members.get(public) {
                        if old != payload {
                            return err("identity-conflict");
                        }
                        return self.snapshot();
                    }
                    self.room_for(public)?;
                    let mut s = self.state.clone();
                    s.members.insert(public.into(), payload.clone());
                    return self.commit(s);
                }
                _ => {}
            }
        }
        match op {
            "snapshot" => self.snapshot(),
            "enroll" => {
                let request = v.get("request").ok_or("request")?;
                let payload = verify_subject(request)?;
                let cert = v.get("credential").ok_or("credential")?;
                let c = verify(cert, &pk(&self.key), "credential")?;
                let id = field(c, "id")?;
                let public = field(payload, "public")?;
                if field(payload, "credential")? != id || field(c, "role")? != "server" {
                    return err("credential-binding");
                }
                verify(
                    v.get("delegation").ok_or("delegation")?,
                    field(c, "holder")?,
                    "enrollment",
                )?;
                if v["delegation"]["payload"] != *payload {
                    return err("delegation-binding");
                }
                if self.state.credentials.get(id) != Some(cert) {
                    return err("unregistered-credential");
                }
                if self.state.removed.contains(public) {
                    return err("removed-identity");
                }
                // A retry can recover a witnessed admission after expiry or credential revocation.
                if let Some(old) = self.state.members.get(public) {
                    if old != payload {
                        return err("identity-conflict");
                    }
                    return self.snapshot();
                }
                if let Some(old) = self.state.allocations.get(id) {
                    if old != payload {
                        return err("already-redeemed");
                    }
                }
                if self.state.revoked.contains(id) || self.now()? >= num(c, "expires")? {
                    return err("fresh-approval-required");
                }
                if public == field(c, "holder")? {
                    return err("key-purpose-reuse");
                }
                self.room_for(public)?;
                let mut s = self.state.clone();
                if field(c, "mode")? == "single-use" {
                    s.allocations.insert(id.into(), payload.clone());
                }
                s.members.insert(public.into(), payload.clone());
                self.commit(s)
            }
            _ => err("operator-only-or-unknown"),
        }
    }
}
fn verify_subject(request: &Value) -> Result<&Value> {
    let payload = request.get("payload").ok_or("payload")?;
    let public = field(payload, "public")?;
    verify(request, public, "enrollment")?;
    if payload.as_object().map(|m| m.len()) != Some(8)
        || field(payload, "role")? != "server"
        || num(payload, "version")? != 1
        || field(payload, "name")?.len() > 128
        || payload.get("relay").and_then(Value::as_bool).is_none()
    {
        return err("enrollment-schema");
    }
    if field(payload, "credential")?.len() > 128 {
        return err("credential-id");
    }
    Ok(payload)
}
fn open_authority(path: PathBuf, seed: [u8; 32], fixture: bool) -> Result<Authority> {
    let key = SigningKey::from_bytes(&seed);
    let file = OpenOptions::new()
        .read(true)
        .append(true)
        .create(true)
        .open(&path)
        .map_err(|e| e.to_string())?;
    // The lock covers the inode used for every append and the entire process lifetime.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return err("journal-locked");
    }
    File::open(path.parent().ok_or("parent")?)
        .and_then(|d| d.sync_all())
        .map_err(|e| e.to_string())?;
    let mut r = BufReader::new(file.try_clone().map_err(|e| e.to_string())?);
    let mut state = State::default();
    let mut sequence = 0;
    let mut previous = String::new();
    while let Some(event) = read_json(&mut r)? {
        let p = verify(&event, &pk(&key), "journal")?;
        if num(p, "sequence")? != sequence + 1 || field(p, "previous")? != previous {
            return err("journal-chain");
        }
        state = serde_json::from_value(p["state"].clone()).map_err(|_| "state-schema")?;
        sequence += 1;
        previous = digest(&event)?;
    }
    Ok(Authority {
        key,
        state,
        journal: file,
        sequence,
        previous,
        fixture,
        fixture_now: None,
        base_wall: wall()?,
        base_mono: Instant::now(),
        crash: false,
        crash_before: false,
    })
}
fn connection(mut stream: TcpStream, shared: Arc<Mutex<Authority>>) -> Result<()> {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| e.to_string())?;
    let v = read_json(&mut BufReader::new(
        stream.try_clone().map_err(|e| e.to_string())?,
    ))?
    .ok_or("eof")?;
    let result = shared
        .lock()
        .map_err(|_| "lock-poisoned")?
        .command(&v, false);
    writeln!(stream, "{}", response(result)).map_err(|e| e.to_string())
}

struct Endpoint {
    key: SigningKey,
    root: String,
    cached: Option<Value>,
    accepted: BTreeMap<String, Value>,
    fixture: bool,
}
impl Endpoint {
    fn now(&self, v: &Value) -> Result<u64> {
        if v.get("now").is_some() {
            if !self.fixture {
                return err("fixture-disabled");
            }
            return num(v, "now");
        }
        wall()
    }
    fn command(&mut self, v: &Value) -> Result<Value> {
        match field(v, "op")? {
            "public" => Ok(json!(pk(&self.key))),
            "request" => {
                let name = field(v, "name")?;
                let id = field(v, "credential")?;
                let relay = v.get("relay").and_then(Value::as_bool).unwrap_or(false);
                sign(
                    &self.key,
                    json!({"purpose":"enrollment","account":ACCOUNT,"credential":id,"public":pk(&self.key),"name":name,"relay":relay,"role":"server","version":1}),
                )
            }
            "delegate" => {
                let request = v.get("request").ok_or("request")?;
                let payload = verify_subject(request)?;
                let cert = v.get("credential").ok_or("credential")?;
                let c = verify(cert, &self.root, "credential")?;
                if field(c, "holder")? != pk(&self.key)
                    || field(c, "id")? != field(payload, "credential")?
                {
                    return err("holder-binding");
                }
                sign(&self.key, payload.clone())
            }
            "snapshot" => {
                let signed = v.get("snapshot").ok_or("snapshot")?;
                let p = verify(signed, &self.root, "directory")?;
                if let Some(old) = &self.cached {
                    if num(p, "sequence")? < num(old, "sequence")?
                        || (p["sequence"] == old["sequence"] && p != old)
                    {
                        return err("rollback-or-fork");
                    }
                }
                let state: State =
                    serde_json::from_value(p["state"].clone()).map_err(|_| "state-schema")?;
                // Locally provisional admission cannot prove ordering before a newly learned revocation.
                self.accepted.retain(|public, record| {
                    !state.removed.contains(public)
                        && (state.members.contains_key(public)
                            || !state
                                .revoked
                                .contains(record["credential"].as_str().unwrap_or("")))
                });
                for (public, record) in &state.members {
                    self.accepted.insert(public.clone(), record.clone());
                }
                self.cached = Some(p.clone());
                let provisional: Vec<&String> = self
                    .accepted
                    .keys()
                    .filter(|k| !state.members.contains_key(*k))
                    .collect();
                Ok(
                    json!({"members":state.members,"provisional":provisional,"sequence":p["sequence"]}),
                )
            }
            "recognize" => {
                let request = v.get("request").ok_or("request")?;
                let p = verify_subject(request)?;
                let public = field(p, "public")?;
                let snapshot = self.cached.as_ref().ok_or("no-cache")?;
                let state: State = serde_json::from_value(snapshot["state"].clone())
                    .map_err(|_| "state-schema")?;
                if state.removed.contains(public) {
                    return err("removed-identity");
                }
                if let Some(old) = self.accepted.get(public) {
                    if old != p {
                        return err("identity-conflict");
                    }
                    return Ok(
                        json!({"accepted":public,"basis":if state.members.contains_key(public) {"canonical"} else {"locally-witnessed-provisional"}}),
                    );
                }
                let cert = v.get("credential").ok_or("credential")?;
                let c = verify(cert, &self.root, "credential")?;
                let id = field(c, "id")?;
                if field(c, "mode")? != "reusable" {
                    return err("single-use-needs-authority");
                }
                if state.credentials.get(id) != Some(cert) || field(p, "credential")? != id {
                    return err("credential-binding");
                }
                if state.revoked.contains(id) || self.now(v)? >= num(c, "expires")? {
                    return err("fresh-approval-required");
                }
                let delegated = verify(
                    v.get("delegation").ok_or("delegation")?,
                    field(c, "holder")?,
                    "enrollment",
                )?;
                if delegated != p {
                    return err("delegation-binding");
                }
                if public == field(c, "holder")? {
                    return err("key-purpose-reuse");
                }
                self.accepted.insert(public.into(), p.clone());
                Ok(json!({"accepted":public,"basis":"offline-delegation"}))
            }
            "warnings" => {
                let c = verify(
                    v.get("credential").ok_or("credential")?,
                    &self.root,
                    "credential",
                )?;
                let now = self.now(v)?;
                let expiry = num(c, "expires")?;
                Ok(json!(if now >= expiry {
                    "expired"
                } else if expiry - now <= 86400 {
                    "one-day"
                } else if expiry - now <= 604800 {
                    "seven-days"
                } else {
                    "none"
                }))
            }
            _ => err("unknown"),
        }
    }
}
fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut stdin = std::io::stdin().lock();
    let init = read_json(&mut stdin)?.ok_or("init")?;
    if args.get(1).map(String::as_str) == Some("authority") {
        let seed: [u8; 32] = hex::decode(field(&init, "seed")?)
            .map_err(|_| "seed")?
            .try_into()
            .map_err(|_| "seed")?;
        let state = open_authority(
            PathBuf::from(args.get(2).ok_or("journal")?),
            seed,
            args.iter().any(|a| a == "--fixture-clock"),
        )?;
        let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
        output(
            &json!({"ready":true,"address":listener.local_addr().map_err(|e|e.to_string())?.to_string(),"public":pk(&state.key)}),
        )?;
        let shared = Arc::new(Mutex::new(state));
        let network = shared.clone();
        std::thread::spawn(move || {
            for result in listener.incoming() {
                match result {
                    Ok(stream) => {
                        let s = network.clone();
                        std::thread::spawn(move || {
                            if let Err(e) = connection(stream, s) {
                                eprintln!("connection:{e}");
                            }
                        });
                    }
                    Err(e) => {
                        eprintln!("listener:{e}");
                        break;
                    }
                }
            }
        });
        while let Some(v) = read_json(&mut stdin)? {
            output(&response(
                shared
                    .lock()
                    .map_err(|_| "lock-poisoned")?
                    .command(&v, true),
            ))?;
        }
    } else if args.get(1).map(String::as_str) == Some("endpoint") {
        let root = field(&init, "root")?.to_string();
        key(&root)?;
        let mut endpoint = Endpoint {
            key: SigningKey::generate(&mut OsRng),
            root,
            cached: None,
            accepted: BTreeMap::new(),
            fixture: args.iter().any(|a| a == "--fixture-clock"),
        };
        output(&json!({"ready":true,"public":pk(&endpoint.key)}))?;
        while let Some(v) = read_json(&mut stdin)? {
            output(&response(endpoint.command(&v)))?;
        }
    } else {
        return err("mode");
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
