// Throwaway Rust endpoint. The production membership protocol is deliberately absent.
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::{self, BufRead, Write};
use std::time::{Duration, Instant};

#[link(name = "myterm_pake", kind = "static")]
extern "C" {
    fn mt_start(
        approver: c_int,
        code: *const c_char,
        binding: *const c_char,
        message: *mut c_char,
        capacity: usize,
    ) -> *mut c_void;
    fn mt_finish(
        p: *mut c_void,
        message: *const c_char,
        proof: *mut c_char,
        capacity: usize,
    ) -> c_int;
    fn mt_verify(p: *mut c_void, proof: *const c_char) -> c_int;
    fn mt_free(p: *mut c_void);
}
struct Context(*mut c_void);
impl Drop for Context {
    fn drop(&mut self) {
        unsafe { mt_free(self.0) }
    }
}
fn input(lines: &mut impl Iterator<Item = io::Result<String>>) -> Result<CString, String> {
    let line = lines
        .next()
        .ok_or("missing input")?
        .map_err(|e| e.to_string())?;
    if line.len() > 8192 || !line.bytes().all(|b| b > 0 && b < 128) {
        return Err("invalid input".into());
    }
    CString::new(line).map_err(|_| "invalid input".into())
}
fn emit(line: &str) -> Result<(), String> {
    let mut out = io::stdout().lock();
    writeln!(out, "{line}")
        .and_then(|_| out.flush())
        .map_err(|e| e.to_string())
}
fn run() -> Result<(), String> {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let code = input(&mut lines)?;
    let binding = input(&mut lines)?;
    let born = Instant::now();
    let fixture_clock = std::env::args().skip(1).any(|a| a == "--fixture-clock");
    let mut offset = Duration::ZERO;
    let mut attempts = 0;
    let mut used = false;
    loop {
        let action = input(&mut lines)?;
        let action = action.to_str().map_err(|e| e.to_string())?;
        if fixture_clock && action.starts_with("ADVANCE ") {
            let seconds: u64 = action[8..].parse().map_err(|_| "bad fixture time")?;
            offset = offset
                .checked_add(Duration::from_secs(seconds))
                .ok_or("fixture time overflow")?;
            emit("ADVANCED")?;
            continue;
        }
        if action != "BEGIN" {
            return Err("unknown action".into());
        }
        if used || attempts >= 5 || born.elapsed() + offset >= Duration::from_secs(300) {
            emit("REJECT")?;
            continue;
        }
        // Reserve an attempt before the exchange so an abandoned exchange spends its slot.
        attempts += 1;
        let mut message = [0 as c_char; 1024];
        // The C bridge owns its opaque context and bounds every output below 1024 bytes.
        let ctx = Context(unsafe {
            mt_start(
                1,
                code.as_ptr(),
                binding.as_ptr(),
                message.as_mut_ptr(),
                message.len(),
            )
        });
        if ctx.0.is_null() {
            return Err("start rejected".into());
        }
        emit(
            unsafe { CStr::from_ptr(message.as_ptr()) }
                .to_str()
                .map_err(|e| e.to_string())?,
        )?;
        let peer_message = input(&mut lines)?;
        let mut proof = [0 as c_char; 1024];
        if unsafe {
            mt_finish(
                ctx.0,
                peer_message.as_ptr(),
                proof.as_mut_ptr(),
                proof.len(),
            )
        } != 1
        {
            return Err("exchange rejected".into());
        }
        emit(
            unsafe { CStr::from_ptr(proof.as_ptr()) }
                .to_str()
                .map_err(|e| e.to_string())?,
        )?;
        let peer_proof = input(&mut lines)?;
        let verified = unsafe { mt_verify(ctx.0, peer_proof.as_ptr()) } == 1;
        used = verified && born.elapsed() + offset < Duration::from_secs(300);
        emit(if used { "PEER_VERIFIED" } else { "REJECT" })?;
    }
}
fn main() {
    if run().is_err() {
        let _ = emit("REJECT");
        std::process::exit(1);
    }
}
