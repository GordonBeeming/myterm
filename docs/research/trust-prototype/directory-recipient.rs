// Native recipient with fixture-pinned account, sender, epoch and membership checkpoint.
use std::ffi::c_void;
use std::io::{self, BufRead, Write};
extern "C" {
    fn mt_directory_new(public: *mut u8, capacity: usize) -> *mut c_void;
    fn mt_directory_free(recipient: *mut c_void);
    fn mt_directory_delegate(
        holder: *mut c_void,
        peer: *const u8,
        peer_len: usize,
        context: *const u8,
        context_len: usize,
        enc: *mut u8,
        enc_cap: usize,
        enc_len: *mut usize,
        wrapped: *mut u8,
        wrapped_cap: usize,
        wrapped_len: *mut usize,
    ) -> i32;
    fn mt_directory_open(
        recipient: *mut c_void,
        sender: *const u8,
        sender_len: usize,
        context: *const u8,
        context_len: usize,
        enc: *const u8,
        enc_len: usize,
        wrapped: *const u8,
        wrapped_len: usize,
        snapshot: *const u8,
        snapshot_len: usize,
        plaintext: *mut u8,
        capacity: usize,
        plaintext_len: *mut usize,
        digest: *mut u8,
        digest_capacity: usize,
    ) -> i32;
}
type Result<T> = std::result::Result<T, String>;
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn unhex(s: &str) -> Result<Vec<u8>> {
    fn d(b: u8) -> Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            _ => Err("encoding".into()),
        }
    }
    if s.len() % 2 != 0 || s.len() > 8192 {
        return Err("encoding".into());
    }
    s.as_bytes()
        .chunks_exact(2)
        .map(|p| Ok((d(p[0])? << 4) | d(p[1])?))
        .collect()
}
fn emit(s: &str) -> Result<()> {
    let mut out = io::stdout().lock();
    writeln!(out, "{s}")
        .and_then(|_| out.flush())
        .map_err(|_| "output".into())
}
struct Recipient(*mut c_void);
impl Drop for Recipient {
    fn drop(&mut self) {
        unsafe { mt_directory_free(self.0) }
    }
}
fn run() -> Result<()> {
    let mut public = [0u8; 65];
    let recipient = Recipient(unsafe { mt_directory_new(public.as_mut_ptr(), public.len()) });
    if recipient.0.is_null() {
        return Err("identity".into());
    }
    emit(&format!("RECIPIENT|{}", hex(&public)))?;
    let stdin = io::stdin();
    let mut expected_context = String::new();
    let mut sender = Vec::new();
    let mut epoch = 0u64;
    for line in stdin.lock().lines() {
        let line = line.map_err(|_| "input")?;
        if line.len() > 32768 {
            return Err("input".into());
        }
        let p: Vec<_> = line.split('|').collect();
        if p.len() == 1 && p[0] == "QUIT" {
            break;
        }
        if p.len() == 5 && p[0] == "PIN" {
            if epoch != 0 {
                emit("REJECT|already-pinned")?;
                continue;
            }
            let next = p[2].parse::<u64>().map_err(|_| "epoch")?;
            sender = unhex(p[4])?;
            if unhex(p[1])?.len() != 32
                || unhex(p[3])?.len() != 32
                || sender.len() != 65
                || next == 0
            {
                return Err("pin".into());
            }
            expected_context = format!("D0|{}|{}|{}", p[1], next, p[3]);
            epoch = next;
            emit("PINNED")?;
            continue;
        }
        if p.len() == 3 && p[0] == "ADVANCE" {
            let next = p[1].parse::<u64>().map_err(|_| "epoch")?;
            if next <= epoch || epoch == 0 || unhex(p[2])?.len() != 32 {
                emit("REJECT|epoch")?;
                continue;
            }
            let fields: Vec<_> = expected_context.split('|').collect();
            expected_context = format!("D0|{}|{}|{}", fields[1], next, p[2]);
            epoch = next;
            emit("ADVANCED")?;
            continue;
        }
        if p.len() == 2 && p[0] == "DELEGATE" && epoch > 0 {
            let peer = unhex(p[1])?;
            let mut enc = [0u8; 65];
            let mut wrapped = [0u8; 48];
            let mut enc_len = 0;
            let mut wrapped_len = 0;
            let ok = unsafe {
                mt_directory_delegate(
                    recipient.0,
                    peer.as_ptr(),
                    peer.len(),
                    expected_context.as_ptr(),
                    expected_context.len(),
                    enc.as_mut_ptr(),
                    enc.len(),
                    &mut enc_len,
                    wrapped.as_mut_ptr(),
                    wrapped.len(),
                    &mut wrapped_len,
                )
            };
            if ok == 1 {
                emit(&format!(
                    "ENVELOPE|{}|{}",
                    hex(&enc[..enc_len]),
                    hex(&wrapped[..wrapped_len])
                ))?;
            } else {
                emit("REJECT|no-bootstrap-key")?;
            }
            continue;
        }
        if p.len() != 5 || p[0] != "OPEN" || epoch == 0 {
            return Err("command".into());
        }
        let context = unhex(p[1])?;
        if context != expected_context.as_bytes() {
            emit("REJECT|context")?;
            continue;
        }
        let enc = unhex(p[2])?;
        let wrapped = unhex(p[3])?;
        let snapshot = unhex(p[4])?;
        let mut plaintext = vec![0u8; 4096];
        let mut len = 0;
        let mut digest = [0u8; 32];
        let ok = unsafe {
            mt_directory_open(
                recipient.0,
                sender.as_ptr(),
                sender.len(),
                context.as_ptr(),
                context.len(),
                enc.as_ptr(),
                enc.len(),
                wrapped.as_ptr(),
                wrapped.len(),
                snapshot.as_ptr(),
                snapshot.len(),
                plaintext.as_mut_ptr(),
                plaintext.len(),
                &mut len,
                digest.as_mut_ptr(),
                digest.len(),
            )
        };
        if ok == 1 {
            plaintext.truncate(len);
            emit(&format!("OPENED|{}|{}", hex(&plaintext), hex(&digest)))?;
        } else {
            emit("REJECT|authentication")?;
        }
    }
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        let _ = emit(&format!("ERROR|{e}"));
        std::process::exit(1);
    }
}
