// Throwaway native launchd/Keychain probe; this is not the MyTerm server.
use std::{env, ffi::{c_void, CString}, fs::{self, OpenOptions}, io::{Read, Write}, os::{fd::AsRawFd, unix::{fs::{MetadataExt, OpenOptionsExt, PermissionsExt}, net::{UnixListener, UnixStream}}}, path::Path, ptr, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecKeychainSetUserInteractionAllowed(allowed: u8) -> i32;
    fn SecKeychainOpen(path: *const i8, out: *mut *mut c_void) -> i32;
    fn SecKeychainAddGenericPassword(k: *mut c_void, sl: u32, s: *const i8, al: u32, a: *const i8, len: u32, data: *const c_void, item: *mut *mut c_void) -> i32;
    fn SecKeychainFindGenericPassword(k: *mut c_void, sl: u32, s: *const i8, al: u32, a: *const i8, len: *mut u32, data: *mut *mut c_void, item: *mut *mut c_void) -> i32;
    fn SecKeychainItemFreeContent(attrs: *mut c_void, data: *mut c_void) -> i32;
}
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" { fn CFRelease(value: *mut c_void); }
extern "C" {
    fn getuid() -> u32;
    fn flock(fd: i32, op: i32) -> i32;
    fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
    fn CC_SHA256(data: *const c_void, len: u32, digest: *mut u8) -> *mut u8;
}

fn key(service: &str, provision: bool) -> Result<String, String> {
    if !service.starts_with("com.gordonbeeming.myterm.native-probe168.") || (provision && service != "com.gordonbeeming.myterm.native-probe168.disposable-key") {
        return Err("refusing key access outside the disposable probe namespace".into());
    }
    let path = CString::new("/Library/Keychains/System.keychain").unwrap();
    let name = CString::new(service).map_err(|e| e.to_string())?;
    let account = b"disposable-native-probe";
    let mut store = ptr::null_mut();
    // Suppress Security Agent UI even when an ACL or locked store denies access.
    let policy = unsafe { SecKeychainSetUserInteractionAllowed(0) };
    if policy != 0 { return Err(format!("interaction-policy OSStatus={policy}")); }
    let opened = unsafe { SecKeychainOpen(path.as_ptr(), &mut store) };
    if opened != 0 { return Err(format!("open OSStatus={opened}")); }
    let result = if provision {
        let mut secret = [0u8; 32];
        let result = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut secret));
        if let Err(e) = result { unsafe { CFRelease(store); } return Err(e.to_string()); }
        let status = unsafe { SecKeychainAddGenericPassword(store, service.len() as u32, name.as_ptr(), account.len() as u32, account.as_ptr().cast(), 32, secret.as_ptr().cast(), ptr::null_mut()) };
        secret.fill(0);
        if status == 0 { Ok("created disposable item".into()) } else { Err(format!("provision OSStatus={status}; existing items are never replaced")) }
    } else {
        let mut len = 0;
        let mut data = ptr::null_mut();
        let status = unsafe { SecKeychainFindGenericPassword(store, service.len() as u32, name.as_ptr(), account.len() as u32, account.as_ptr().cast(), &mut len, &mut data, ptr::null_mut()) };
        if status == 0 {
            let mut digest = [0u8; 32];
            unsafe { CC_SHA256(data, len, digest.as_mut_ptr()); SecKeychainItemFreeContent(ptr::null_mut(), data); }
            if len != 32 { Err(format!("unexpected item length={len}")) }
            else { Ok(digest.iter().map(|b| format!("{b:02x}")).collect()) }
        } else { Err(format!("read OSStatus={status}; needs attention; identity retained")) }
    };
    unsafe { CFRelease(store); }
    result
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).ok_or("expected serve, request, provision or key-check")?;
    if mode == "provision" || mode == "key-check" {
        if mode == "provision" && unsafe { getuid() } != 0 { return Err("provision requires administrator execution".into()); }
        println!("{}", key(args.get(2).ok_or("missing service name")?, mode == "provision")?);
        return Ok(());
    }
    let root = Path::new(args.get(2).ok_or("missing instance directory")?);
    if mode == "request" {
        let mut stream = UnixStream::connect(root.join("control.sock"))?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        stream.write_all(args.get(3).ok_or("missing command")?.as_bytes())?;
        stream.shutdown(std::net::Shutdown::Write)?;
        let mut result = String::new(); stream.read_to_string(&mut result)?;
        print!("{result}"); return Ok(());
    }
    if mode != "serve" { return Err("unknown mode".into()); }
    if unsafe { getuid() } == 0 { return Err("server refuses root execution".into()); }
    let service = args.get(3).ok_or("missing key service")?;
    fs::create_dir_all(root)?;
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    let lock = OpenOptions::new().create(true).truncate(false).read(true).write(true).mode(0o600).open(root.join("owner.lock"))?;
    if unsafe { flock(lock.as_raw_fd(), 2 | 4) } != 0 { return Err("instance already owned".into()); }
    let socket = root.join("control.sock");
    match fs::remove_file(&socket) { Ok(()) => {}, Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}, Err(e) => return Err(e.into()) }
    let listener = UnixListener::bind(&socket)?;
    listener.set_nonblocking(true)?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
    let started = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let identity = match fs::read_to_string(root.join("instance-id")) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let id = format!("probe-{}-{started}", std::process::id());
            let mut file = OpenOptions::new().create_new(true).write(true).mode(0o600).open(root.join("instance-id"))?;
            file.write_all(id.as_bytes())?; id
        },
        Err(e) => return Err(e.into())
    };
    println!("started={started} pid={} uid={} instance={identity}", std::process::id(), unsafe { getuid() });
    let mut heartbeat = Instant::now();
    loop {
        if heartbeat.elapsed() >= Duration::from_secs(5) {
            let at = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
            let console_uid = fs::metadata("/dev/console").map(|m| m.uid());
            println!("heartbeat={at} pid={} uid={} console_uid={console_uid:?} instance={identity} key={:?}", std::process::id(), unsafe { getuid() }, key(service, false));
            heartbeat = Instant::now();
        }
        let mut stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => { std::thread::sleep(Duration::from_millis(50)); continue; },
            Err(e) => { eprintln!("accept: {e}"); std::thread::sleep(Duration::from_millis(100)); continue; }
        };
        if let Err(e) = stream.set_nonblocking(false) { eprintln!("blocking request: {e}"); continue; }
        if let Err(e) = stream.set_read_timeout(Some(Duration::from_secs(2))) { eprintln!("request timeout: {e}"); continue; }
        if let Err(e) = stream.set_write_timeout(Some(Duration::from_secs(2))) { eprintln!("response timeout: {e}"); continue; }
        let (mut uid, mut gid) = (0, 0);
        if unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 || uid != unsafe { getuid() } { continue; }
        let mut buf = [0u8; 256];
        let count = match stream.read(&mut buf) { Ok(n) => n, Err(e) => { eprintln!("request read: {e}"); continue; } };
        let command = match std::str::from_utf8(&buf[..count]) { Ok(s) => s.trim(), Err(e) => { eprintln!("invalid request: {e}"); continue; } };
        let result = match command {
            "status" => format!("pid={} uid={} started={started} instance={identity}\n", std::process::id(), unsafe { getuid() }),
            "key" => format!("{:?}\n", key(service, false)),
            _ => "unsupported command\n".into(),
        };
        if let Err(e) = stream.write_all(result.as_bytes()) { eprintln!("response write: {e}"); }
    }
}
fn main() { if let Err(e) = run() { eprintln!("{e}"); std::process::exit(1); } }
