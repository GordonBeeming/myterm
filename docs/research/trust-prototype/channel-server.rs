// Throwaway native server. The pipe-owned shell belongs to this server, not to a TLS connection.
use std::ffi::{c_char, c_void, CStr};
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

extern "C" {
    fn mt_public_key(seed: *const u8, len: usize, out: *mut u8, capacity: usize) -> i32;
    fn mt_clear(bytes: *mut u8, len: usize);
    fn mt_tls_new(
        server: i32,
        seed: *const u8,
        len: usize,
        peer: *const u8,
        peer_len: usize,
    ) -> *mut c_void;
    fn mt_tls_pump(
        tls: *mut c_void,
        input: *const u8,
        len: usize,
        cipher: *mut u8,
        cap: usize,
        cipher_len: *mut usize,
        plain: *mut u8,
        plain_cap: usize,
        plain_len: *mut usize,
    ) -> i32;
    fn mt_tls_write(tls: *mut c_void, input: *const u8, len: usize) -> i32;
    fn mt_tls_update(tls: *mut c_void) -> i32;
    fn mt_tls_open(tls: *mut c_void) -> i32;
    fn mt_tls_fingerprint(tls: *mut c_void, out: *mut u8, capacity: usize) -> i32;
    fn mt_tls_free(tls: *mut c_void);
    fn mt_tls_last_error() -> *const c_char;
    fn mt_tls_updates_sent(tls: *mut c_void) -> usize;
    fn mt_tls_updates_received(tls: *mut c_void) -> usize;
}
type Result<T> = std::result::Result<T, String>;
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex(text: &str) -> Result<Vec<u8>> {
    if text.len() % 2 != 0 || text.len() > 1048576 {
        return Err("encoding".into());
    }
    fn digit(c: u8) -> Result<u8> {
        match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            _ => Err("encoding".into()),
        }
    }
    text.as_bytes()
        .chunks_exact(2)
        .map(|p| Ok((digit(p[0])? << 4) | digit(p[1])?))
        .collect()
}
fn emit(text: &str) -> Result<()> {
    let mut out = io::stdout().lock();
    writeln!(out, "{text}")
        .and_then(|_| out.flush())
        .map_err(|_| "output".into())
}
struct Secret(Vec<u8>);
impl Drop for Secret {
    fn drop(&mut self) {
        unsafe { mt_clear(self.0.as_mut_ptr(), self.0.len()) }
    }
}
struct Tls(*mut c_void);
impl Drop for Tls {
    fn drop(&mut self) {
        unsafe { mt_tls_free(self.0) }
    }
}
struct Session {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    pending: Vec<u8>,
}
impl Session {
    fn new() -> Result<Self> {
        let script = r#"printf 'READY:%s\n' "$$"; while IFS= read -r line; do printf '\033[32mECHO:%s:%s\033[0m\n' "$$" "$line"; done"#;
        let mut child = Command::new("/bin/sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "shell-spawn")?;
        let input = child.stdin.take().ok_or("shell-input")?;
        let output = BufReader::new(child.stdout.take().ok_or("shell-output")?);
        let mut session = Self {
            child,
            input,
            output,
            pending: Vec::new(),
        };
        let mut greeting = String::new();
        session
            .output
            .read_line(&mut greeting)
            .map_err(|_| "shell-greeting")?;
        if greeting.trim_end() != format!("READY:{}", session.child.id()) {
            return Err("shell-pid".into());
        }
        Ok(session)
    }
    fn feed(&mut self, input: &[u8]) -> Result<Vec<u8>> {
        if self.pending.len() + input.len() > 131072 {
            return Err("shell-fixture-limit".into());
        }
        self.pending.extend_from_slice(input);
        let mut output = Vec::new();
        while let Some(end) = self.pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=end).collect();
            self.input
                .write_all(&line)
                .and_then(|_| self.input.flush())
                .map_err(|_| "shell-write")?;
            let read = self
                .output
                .read_until(b'\n', &mut output)
                .map_err(|_| "shell-read")?;
            if read == 0 || output.len() > 131072 {
                return Err("shell-output".into());
            }
        }
        Ok(output)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        match self.child.try_wait() {
            Ok(Some(_)) => (),
            _ => {
                if let Err(e) = self.child.kill() {
                    eprintln!("fixture shell cleanup: {e}");
                }
                if let Err(e) = self.child.wait() {
                    eprintln!("fixture shell wait: {e}");
                }
            }
        }
    }
}
fn pump(tls: &Tls, input: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut cipher = vec![0u8; 131072];
    let mut plain = vec![0u8; 131072];
    let mut cipher_len = 0;
    let mut plain_len = 0;
    if unsafe {
        mt_tls_pump(
            tls.0,
            input.as_ptr(),
            input.len(),
            cipher.as_mut_ptr(),
            cipher.len(),
            &mut cipher_len,
            plain.as_mut_ptr(),
            plain.len(),
            &mut plain_len,
        )
    } != 1
    {
        let error = unsafe { mt_tls_last_error() };
        let detail = if error.is_null() {
            "unknown".into()
        } else {
            unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned()
        };
        return Err(format!("tls:{detail}"));
    }
    cipher.truncate(cipher_len);
    plain.truncate(plain_len);
    Ok((cipher, plain))
}
fn frame(tls: &Tls, input: &[u8], session: &mut Session) -> Result<String> {
    let (mut cipher, plain) = pump(tls, input)?;
    let reply = session.feed(&plain)?;
    for chunk in reply.chunks(65536) {
        if unsafe { mt_tls_write(tls.0, chunk.as_ptr(), chunk.len()) } != 1 {
            return Err("tls-write".into());
        }
    }
    if !reply.is_empty() {
        let (extra, unexpected) = pump(tls, &[])?;
        if !unexpected.is_empty() {
            return Err("unexpected-pipeline".into());
        }
        cipher.extend(extra);
    }
    let open = unsafe { mt_tls_open(tls.0) } == 1;
    let mut fingerprint = [0u8; 32];
    if open
        && unsafe { mt_tls_fingerprint(tls.0, fingerprint.as_mut_ptr(), fingerprint.len()) } != 1
    {
        return Err("fingerprint".into());
    }
    Ok(format!(
        "FRAME|{}||{}|{}",
        hex(&cipher),
        if open { 1 } else { 0 },
        if open {
            hex(&fingerprint)
        } else {
            String::new()
        }
    ))
}
fn run() -> Result<()> {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let seed_line = lines.next().ok_or("seed")?.map_err(|_| "input")?;
    let seed = Secret(unhex(seed_line.strip_prefix("SEED|").ok_or("seed")?)?);
    let mut public = [0u8; 32];
    if unsafe {
        mt_public_key(
            seed.0.as_ptr(),
            seed.0.len(),
            public.as_mut_ptr(),
            public.len(),
        )
    } != 1
    {
        return Err("seed".into());
    }
    let mut session = Session::new()?;
    emit(&format!("KEY|{}|{}", hex(&public), session.child.id()))?;
    let mut tls: Option<Tls> = None;
    while let Some(line) = lines.next() {
        let line = line.map_err(|_| "input")?;
        if line.len() > 1048576 {
            return Err("input".into());
        }
        let p: Vec<_> = line.split('|').collect();
        if p.len() == 1 && p[0] == "QUIT" {
            break;
        }
        if p.len() == 2 && p[0] == "EXPECT" {
            drop(tls.take());
            let peer = unhex(p[1])?;
            let context =
                unsafe { mt_tls_new(1, seed.0.as_ptr(), seed.0.len(), peer.as_ptr(), peer.len()) };
            if context.is_null() {
                return Err("identity".into());
            }
            tls = Some(Tls(context));
            emit("READY")?;
            continue;
        }
        if p.len() == 1 && p[0] == "PID" {
            emit(&format!("PID|{}", session.child.id()))?;
            continue;
        }
        let reply = if let Some(ref context) = tls {
            if p.len() == 2 && p[0] == "PUMP" {
                frame(context, &unhex(p[1])?, &mut session)
            } else if p.len() == 1 && p[0] == "STATS" {
                Ok(format!(
                    "STATS|{}|{}",
                    unsafe { mt_tls_updates_sent(context.0) },
                    unsafe { mt_tls_updates_received(context.0) }
                ))
            } else if p.len() == 1 && p[0] == "UPDATE" {
                if unsafe { mt_tls_update(context.0) } == 1 {
                    Ok("UPDATED".into())
                } else {
                    Err("tls-update".into())
                }
            } else {
                return Err("command".into());
            }
        } else {
            emit("FAILED|no-channel")?;
            continue;
        };
        match reply {
            Ok(response) => emit(&response)?,
            Err(error) => {
                tls = None;
                emit(&format!("FAILED|{error}"))?;
            }
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
