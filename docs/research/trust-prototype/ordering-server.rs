// Throwaway single-authority removal sequencer. No consensus or automatic failover.
use std::collections::{BTreeSet, HashMap};
use std::env;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::Path;

extern "C" {
    fn mt_public_key(seed: *const u8, len: usize, output: *mut u8, capacity: usize) -> i32;
    fn mt_sign_removal(
        seed: *const u8,
        len: usize,
        message: *const u8,
        message_len: usize,
        output: *mut u8,
        capacity: usize,
    ) -> i32;
    fn mt_verify_signature(
        key: *const u8,
        key_len: usize,
        message: *const u8,
        message_len: usize,
        signature: *const u8,
        signature_len: usize,
    ) -> i32;
    fn mt_digest(message: *const u8, len: usize, output: *mut u8, capacity: usize) -> i32;
    fn mt_clear(bytes: *mut u8, len: usize);
    fn flock(fd: i32, operation: i32) -> i32;
}
type ProbeResult<T> = Result<T, String>;
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(text: &str) -> ProbeResult<Vec<u8>> {
    if text.len() % 2 != 0 || text.len() > 32768 {
        return Err("encoding".into());
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            fn digit(c: u8) -> ProbeResult<u8> {
                match c {
                    b'0'..=b'9' => Ok(c - b'0'),
                    b'a'..=b'f' => Ok(c - b'a' + 10),
                    _ => Err("encoding".into()),
                }
            }
            Ok((digit(pair[0])? << 4) | digit(pair[1])?)
        })
        .collect()
}
fn key(text: &str) -> bool {
    text.len() == 64 && unhex(text).is_ok()
}
fn digest(data: &[u8]) -> ProbeResult<String> {
    let mut out = [0u8; 32];
    if unsafe { mt_digest(data.as_ptr(), data.len(), out.as_mut_ptr(), out.len()) } != 1 {
        return Err("digest".into());
    }
    Ok(hex(&out))
}
fn verify(public: &str, message: &[u8], signature: &str) -> ProbeResult<()> {
    let public = unhex(public)?;
    let signature = unhex(signature)?;
    if unsafe {
        mt_verify_signature(
            public.as_ptr(),
            public.len(),
            message.as_ptr(),
            message.len(),
            signature.as_ptr(),
            signature.len(),
        )
    } != 1
    {
        return Err("signature".into());
    }
    Ok(())
}
struct Signer {
    seed: Vec<u8>,
    public: String,
}
impl Signer {
    fn new(mut seed: Vec<u8>) -> ProbeResult<Self> {
        let mut public = [0u8; 32];
        if unsafe { mt_public_key(seed.as_ptr(), seed.len(), public.as_mut_ptr(), public.len()) }
            != 1
        {
            unsafe { mt_clear(seed.as_mut_ptr(), seed.len()) };
            return Err("seed".into());
        }
        Ok(Self {
            seed,
            public: hex(&public),
        })
    }
    fn sign(&self, message: &[u8]) -> ProbeResult<String> {
        let mut signature = [0u8; 64];
        if unsafe {
            mt_sign_removal(
                self.seed.as_ptr(),
                self.seed.len(),
                message.as_ptr(),
                message.len(),
                signature.as_mut_ptr(),
                signature.len(),
            )
        } != 1
        {
            return Err("signing".into());
        }
        Ok(hex(&signature))
    }
}
impl Drop for Signer {
    fn drop(&mut self) {
        unsafe { mt_clear(self.seed.as_mut_ptr(), self.seed.len()) }
    }
}

struct Request {
    body: String,
    issuer: String,
    target: String,
    nonce: String,
    base: String,
}
fn request(body_hex: &str, account: &str) -> ProbeResult<Request> {
    let body = String::from_utf8(unhex(body_hex)?).map_err(|_| "encoding")?;
    let p: Vec<_> = body.split('|').collect();
    if p.len() != 8
        || p[0] != "R0"
        || p[1] != account
        || p[2] != "1"
        || !p[3..].iter().all(|s| key(s))
    {
        return Err("request-context".into());
    }
    // A final reserved field binds this probe's removal-only purpose into every signature.
    if p[7] != "0000000000000000000000000000000000000000000000000000000000000000" {
        return Err("request-purpose".into());
    }
    Ok(Request {
        issuer: p[4].into(),
        target: p[5].into(),
        nonce: p[6].into(),
        base: p[3].into(),
        body,
    })
}
struct State {
    account: String,
    coordinator: String,
    members: BTreeSet<String>,
    seq: u64,
    head: String,
    seen: HashMap<(String, String), (String, String)>,
}
impl State {
    fn validate_request(&self, r: &Request, signature: &str) -> ProbeResult<()> {
        verify(&r.issuer, r.body.as_bytes(), signature)?;
        if !self.members.contains(&r.issuer) {
            return Err("removed-issuer".into());
        }
        if !self.members.contains(&r.target) {
            return Err("unknown-target".into());
        }
        if r.target == self.coordinator {
            return Err("authority-transfer-required".into());
        }
        if r.base != self.head {
            return Err("stale-checkpoint".into());
        }
        if self.seen.contains_key(&(r.issuer.clone(), r.nonce.clone())) {
            return Err("nonce-reuse".into());
        }
        Ok(())
    }
    fn receipt_body(&self, r: &Request, signature: &str) -> ProbeResult<String> {
        let next = self.seq.checked_add(1).ok_or("sequence-overflow")?;
        let request_hash = digest(format!("{}|{}", hex(r.body.as_bytes()), signature).as_bytes())?;
        Ok(format!(
            "C0|{}|1|{}|{}|{}",
            self.account, next, self.head, request_hash
        ))
    }
    fn apply(&mut self, line: &str) -> ProbeResult<()> {
        let p: Vec<_> = line.split('|').collect();
        if p.len() != 5 || p[0] != "COMMIT" {
            return Err("journal-record".into());
        }
        let r = request(p[3], &self.account)?;
        self.validate_request(&r, p[4])?;
        let expected_body = self.receipt_body(&r, p[4])?;
        if unhex(p[1])? != expected_body.as_bytes() {
            return Err("journal-chain".into());
        }
        verify(&self.coordinator, expected_body.as_bytes(), p[2])?;
        self.head = digest(format!("{}|{}", p[1], p[2]).as_bytes())?;
        self.seq = self.seq.checked_add(1).ok_or("sequence-overflow")?;
        self.members.remove(&r.target);
        self.seen.insert((r.issuer, r.nonce), (r.body, line.into()));
        Ok(())
    }
}
fn emit(line: &str) -> ProbeResult<()> {
    let mut out = io::stdout().lock();
    writeln!(out, "{line}")
        .and_then(|_| out.flush())
        .map_err(|_| "output".into())
}
fn input(lines: &mut impl Iterator<Item = io::Result<String>>) -> ProbeResult<String> {
    let line = lines.next().ok_or("missing-input")?.map_err(|_| "input")?;
    if line.len() > 32768 || !line.bytes().all(|b| b > 0 && b < 128) {
        return Err("input".into());
    }
    Ok(line)
}
fn run() -> ProbeResult<()> {
    let args: Vec<_> = env::args().collect();
    if args.len() < 2 || args.len() > 3 {
        return Err("usage".into());
    }
    let crash_after_commit = args
        .get(2)
        .is_some_and(|s| s == "--fixture-crash-after-commit");
    if args.len() == 3 && !crash_after_commit {
        return Err("usage".into());
    }
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    // The bootstrap is a trusted fixture, not a product enrollment or key-storage mechanism.
    let key_line = input(&mut lines)?;
    let key_parts: Vec<_> = key_line.split('|').collect();
    if key_parts.len() != 2 || key_parts[0] != "KEY" || !key(key_parts[1]) {
        return Err("bootstrap-key".into());
    }
    let signer = Signer::new(unhex(key_parts[1])?)?;
    emit(&format!("KEY|{}", signer.public))?;
    let boot = input(&mut lines)?;
    let p: Vec<_> = boot.split('|').collect();
    if p.len() != 3 || p[0] != "BOOT" || !key(p[1]) {
        return Err("bootstrap".into());
    }
    let members: BTreeSet<String> = p[2].split(',').map(String::from).collect();
    if members.len() < 2 || !members.iter().all(|m| key(m)) || !members.contains(&signer.public) {
        return Err("bootstrap-members".into());
    }
    let header = format!(
        "GENESIS|{}|{}|{}",
        p[1],
        signer.public,
        members.iter().cloned().collect::<Vec<_>>().join(",")
    );
    let mut state = State {
        account: p[1].into(),
        coordinator: signer.public.clone(),
        members,
        seq: 0,
        head: digest(header.as_bytes())?,
        seen: HashMap::new(),
    };
    let journal_path = Path::new(&args[1]);
    let mut journal = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(journal_path)
        .map_err(|_| "journal-open")?;
    // Unix-only prototype: the OS lock is released on normal exit and process death.
    if unsafe { flock(journal.as_raw_fd(), 2 | 4) } != 0 {
        return Err("journal-already-locked".into());
    }
    if journal.metadata().map_err(|_| "journal-stat")?.len() > 1024 * 1024 {
        return Err("journal-fixture-limit".into());
    }
    let mut text = String::new();
    journal
        .read_to_string(&mut text)
        .map_err(|_| "journal-read")?;
    if text.is_empty() {
        journal
            .write_all(format!("{header}\n").as_bytes())
            .and_then(|_| journal.sync_all())
            .map_err(|_| "journal-create")?;
        let parent = journal_path.parent().ok_or("journal-parent")?;
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| "journal-directory-sync")?;
    } else {
        if !text.ends_with('\n') {
            return Err("journal-truncated".into());
        }
        let mut records = text.lines();
        if records.next() != Some(header.as_str()) {
            return Err("journal-bootstrap-mismatch".into());
        }
        for record in records {
            state.apply(record)?;
        }
    }
    emit(&format!(
        "READY|{}|{}|{}",
        signer.public, state.seq, state.head
    ))?;
    while let Some(line) = lines.next() {
        let line = line.map_err(|_| "input")?;
        if line.len() > 32768 {
            return Err("input".into());
        }
        if line == "STATE" {
            emit(&format!(
                "STATE|{}|{}|{}",
                state.seq,
                state.head,
                state.members.iter().cloned().collect::<Vec<_>>().join(",")
            ))?;
            continue;
        }
        let p: Vec<_> = line.split('|').collect();
        let outcome = (|| -> ProbeResult<(String, bool)> {
            if p.len() != 3 || p[0] != "REMOVE" {
                return Err("command".into());
            }
            let r = request(p[1], &state.account)?;
            verify(&r.issuer, r.body.as_bytes(), p[2])?;
            if let Some((prior_body, receipt)) =
                state.seen.get(&(r.issuer.clone(), r.nonce.clone()))
            {
                if prior_body != &r.body {
                    return Err("nonce-conflict".into());
                }
                return Ok((receipt.clone(), false));
            }
            state.validate_request(&r, p[2])?;
            let body = state.receipt_body(&r, p[2])?;
            let signature = signer.sign(body.as_bytes())?;
            let receipt = format!(
                "COMMIT|{}|{}|{}|{}",
                hex(body.as_bytes()),
                signature,
                p[1],
                p[2]
            );
            if journal.metadata().map_err(|_| "fatal-journal-stat")?.len()
                + receipt.len() as u64
                + 1
                > 1024 * 1024
            {
                return Err("journal-fixture-limit".into());
            }
            journal
                .write_all(format!("{receipt}\n").as_bytes())
                .and_then(|_| journal.sync_all())
                .map_err(|_| "fatal-journal-write")?;
            state.apply(&receipt).map_err(|_| "fatal-internal-commit")?;
            Ok((receipt, true))
        })();
        match outcome {
            Ok((receipt, fresh)) => {
                if fresh && crash_after_commit {
                    std::process::exit(42);
                }
                emit(&receipt)?;
            }
            Err(e) if e.starts_with("fatal-") => return Err(e),
            Err(e) => emit(&format!("REJECT|{e}"))?,
        }
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        let _ = emit(&format!("FATAL|{e}"));
        std::process::exit(1);
    }
}
