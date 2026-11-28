use crate::session::check;
use std::ffi::{c_char, c_void, CStr};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::ptr;

#[cfg(not(feature = "production"))]
const APP_IDENTIFIER: &str = "com.gordonbeeming.myterm.dev";
#[cfg(not(feature = "production"))]
const SERVER_IDENTIFIER: &str = "com.gordonbeeming.myterm.dev.local-terminal";
#[cfg(feature = "release-rehearsal")]
const APP_IDENTIFIER: &str = "com.gordonbeeming.myterm.rust-rehearsal";
#[cfg(feature = "release-rehearsal")]
const SERVER_IDENTIFIER: &str = "com.gordonbeeming.myterm.rust-rehearsal.local-terminal";
#[cfg(all(feature = "production", not(feature = "release-rehearsal")))]
const APP_IDENTIFIER: &str = "com.gordonbeeming.myterm";
#[cfg(all(feature = "production", not(feature = "release-rehearsal")))]
const SERVER_IDENTIFIER: &str = "com.gordonbeeming.myterm.local-terminal";
const SIGNING_INFORMATION: u32 = 1 << 1;
const HARDENED_RUNTIME: i64 = 0x0001_0000;
const UTF8: u32 = 0x0800_0100;
const NUMBER_I64: i32 = 4;

pub struct ClientAuthentication {
    requirement: OwnedCf,
}

impl ClientAuthentication {
    pub fn new() -> io::Result<Self> {
        let own = copy_security_object("identify local terminal server", |out| unsafe {
            SecCodeCopySelf(0, out)
        })?;
        let information = signing_information(&own)?;
        let team = unsafe { dictionary_value(information.as_ref(), kSecCodeInfoTeamIdentifier) };
        let team = team_identifier(team)?;
        #[cfg(feature = "production")]
        if team != "89DBN36T4T" {
            return Err(untrusted(
                "Unexpected Developer ID signing team for the local terminal server",
            ));
        }
        let own_requirement = requirement(SERVER_IDENTIFIER, &team)?;
        validate_code(&own, &own_requirement)?;
        validate_runtime(&information)?;
        Self::for_team(&team)
    }

    pub fn for_team(team: &str) -> io::Result<Self> {
        Ok(Self {
            requirement: requirement(APP_IDENTIFIER, team)?,
        })
    }

    pub fn authenticate(&self, stream: &UnixStream) -> io::Result<()> {
        let descriptor = stream.as_raw_fd();
        let mut uid = 0;
        let mut gid = 0;
        check(unsafe { libc::getpeereid(descriptor, &mut uid, &mut gid) })?;
        if uid != unsafe { libc::geteuid() } {
            return Err(untrusted(
                "Local terminal client has a different effective UID",
            ));
        }

        // The Darwin audit token pins the peer's process incarnation. A PID can be recycled.
        let mut token = [0u32; 8];
        let mut length = size_of_val(&token) as libc::socklen_t;
        check(unsafe {
            libc::getsockopt(
                descriptor,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERTOKEN,
                token.as_mut_ptr().cast(),
                &mut length,
            )
        })?;
        if length as usize != size_of_val(&token) {
            return Err(untrusted("Invalid local terminal client audit token"));
        }

        let token = OwnedCf::new(
            unsafe { CFDataCreate(ptr::null(), token.as_ptr().cast(), length as isize) },
            "Could not copy local terminal client audit token",
        )?;
        let attributes = OwnedCf::new(
            unsafe {
                CFDictionaryCreate(
                    ptr::null(),
                    &kSecGuestAttributeAudit,
                    &token.as_ref(),
                    1,
                    &kCFTypeDictionaryKeyCallBacks,
                    &kCFTypeDictionaryValueCallBacks,
                )
            },
            "Could not create local terminal client identity attributes",
        )?;
        let peer = copy_security_object("identify local terminal client", |out| unsafe {
            SecCodeCopyGuestWithAttributes(ptr::null(), attributes.as_ref(), 0, out)
        })?;
        validate_code(&peer, &self.requirement)?;
        validate_runtime(&signing_information(&peer)?)
    }
}

fn signing_information(code: &OwnedCf) -> io::Result<OwnedCf> {
    let static_code = copy_security_object("read static code identity", |out| unsafe {
        SecCodeCopyStaticCode(code.as_ref(), 0, out)
    })?;
    copy_security_object("read code signing information", |out| unsafe {
        SecCodeCopySigningInformation(static_code.as_ref(), SIGNING_INFORMATION, out)
    })
}

fn requirement(identifier: &str, team: &str) -> io::Result<OwnedCf> {
    if team.len() != 10 || !team.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        return Err(untrusted("Invalid Apple signing team identifier"));
    }
    let developer_id = if cfg!(feature = "production") {
        " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    } else {
        ""
    };
    let expression = string(&format!(
        "anchor apple generic and identifier \"{identifier}\" and certificate leaf[subject.OU] = \"{team}\"{developer_id}"
    ))?;
    copy_security_object("create code signing requirement", |out| unsafe {
        SecRequirementCreateWithString(expression.as_ref(), 0, out)
    })
}

fn validate_code(code: &OwnedCf, requirement: &OwnedCf) -> io::Result<()> {
    let status = unsafe { SecCodeCheckValidity(code.as_ref(), 0, requirement.as_ref()) };
    security_status("check code signature against signing requirement", status)
}

fn validate_runtime(info: &OwnedCf) -> io::Result<()> {
    let flags = unsafe { dictionary_value(info.as_ref(), kSecCodeInfoFlags) };
    if number(flags).is_none_or(|flags| flags & HARDENED_RUNTIME == 0) {
        return Err(untrusted("Local terminal code is missing hardened runtime"));
    }
    let entitlements = unsafe { dictionary_value(info.as_ref(), kSecCodeInfoEntitlementsDict) };
    if entitlements.is_null() {
        return Ok(());
    }
    for name in [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
    ] {
        let key = string(name)?;
        let value = unsafe { dictionary_value(entitlements, key.as_ref()) };
        let disabled = unsafe {
            value.is_null()
                || (CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value) == 0)
                || number(value) == Some(0)
        };
        if !disabled {
            return Err(untrusted(&format!("Local terminal code permits {name}")));
        }
    }
    Ok(())
}

fn team_identifier(value: CfRef) -> io::Result<String> {
    let mut buffer: [c_char; 11] = [0; 11];
    if value.is_null()
        || unsafe { CFGetTypeID(value) != CFStringGetTypeID() }
        || unsafe { CFStringGetCString(value, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) }
            == 0
    {
        return Err(untrusted(
            "An Apple signing team is required for the local terminal server",
        ));
    }
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| untrusted("Invalid Apple signing team identifier"))
}

fn string(value: &str) -> io::Result<OwnedCf> {
    OwnedCf::new(
        unsafe {
            CFStringCreateWithBytes(ptr::null(), value.as_ptr(), value.len() as isize, UTF8, 0)
        },
        "Could not create Core Foundation string for code signing validation",
    )
}

fn number(value: CfRef) -> Option<i64> {
    let mut result = 0i64;
    if value.is_null()
        || unsafe { CFGetTypeID(value) != CFNumberGetTypeID() }
        || unsafe { CFNumberGetValue(value, NUMBER_I64, (&mut result as *mut i64).cast()) } == 0
    {
        return None;
    }
    Some(result)
}

unsafe fn dictionary_value(dictionary: CfRef, key: CfRef) -> CfRef {
    if dictionary.is_null() || CFGetTypeID(dictionary) != CFDictionaryGetTypeID() {
        return ptr::null();
    }
    CFDictionaryGetValue(dictionary, key)
}

fn copy_security_object(action: &str, copy: impl FnOnce(&mut CfRef) -> i32) -> io::Result<OwnedCf> {
    let mut reference = ptr::null();
    security_status(action, copy(&mut reference))?;
    OwnedCf::new(reference, action)
}

fn security_status(action: &str, status: i32) -> io::Result<()> {
    if status != 0 {
        return Err(untrusted(&format!(
            "Could not {action} (OSStatus {status})"
        )));
    }
    Ok(())
}

fn untrusted(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

type CfRef = *const c_void;

struct OwnedCf(CfRef);

impl OwnedCf {
    fn new(reference: CfRef, action: &str) -> io::Result<Self> {
        if reference.is_null() {
            return Err(untrusted(action));
        }
        Ok(Self(reference))
    }

    fn as_ref(&self) -> CfRef {
        self.0
    }
}

impl Drop for OwnedCf {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) };
    }
}

#[repr(C)]
struct DictionaryKeyCallbacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
    hash: *const c_void,
}

#[repr(C)]
struct DictionaryValueCallbacks {
    version: isize,
    retain: *const c_void,
    release: *const c_void,
    copy_description: *const c_void,
    equal: *const c_void,
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeDictionaryKeyCallBacks: DictionaryKeyCallbacks;
    static kCFTypeDictionaryValueCallBacks: DictionaryValueCallbacks;

    fn CFRelease(object: CfRef);
    fn CFGetTypeID(object: CfRef) -> usize;
    fn CFDataCreate(allocator: CfRef, bytes: *const u8, length: isize) -> CfRef;
    fn CFDictionaryCreate(
        allocator: CfRef,
        keys: *const CfRef,
        values: *const CfRef,
        count: isize,
        key_callbacks: *const DictionaryKeyCallbacks,
        value_callbacks: *const DictionaryValueCallbacks,
    ) -> CfRef;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: CfRef, key: CfRef) -> CfRef;
    fn CFStringCreateWithBytes(
        allocator: CfRef,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external_representation: u8,
    ) -> CfRef;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetCString(string: CfRef, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(number: CfRef, storage_type: i32, output: *mut c_void) -> u8;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(boolean: CfRef) -> u8;
}

#[link(name = "Security", kind = "framework")]
extern "C" {
    static kSecGuestAttributeAudit: CfRef;
    static kSecCodeInfoTeamIdentifier: CfRef;
    static kSecCodeInfoEntitlementsDict: CfRef;
    static kSecCodeInfoFlags: CfRef;

    fn SecCodeCopySelf(flags: u32, output: *mut CfRef) -> i32;
    fn SecCodeCopyStaticCode(code: CfRef, flags: u32, output: *mut CfRef) -> i32;
    fn SecCodeCopySigningInformation(code: CfRef, flags: u32, output: *mut CfRef) -> i32;
    fn SecCodeCheckValidity(code: CfRef, flags: u32, requirement: CfRef) -> i32;
    fn SecRequirementCreateWithString(expression: CfRef, flags: u32, output: *mut CfRef) -> i32;
    fn SecCodeCopyGuestWithAttributes(
        host: CfRef,
        attributes: CfRef,
        flags: u32,
        output: *mut CfRef,
    ) -> i32;
}
