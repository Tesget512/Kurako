//! Apple system HTTP proxy lookup via CFNetwork.
//!
//! GUI-launched apps do not inherit shell proxy environment variables, so the
//! env-var fallback in `detect_system_proxy` never sees the user's proxy
//! setup. Each platform needs a different CFNetwork entry point:
//!
//! * macOS: `CFNetworkCopySystemProxySettings` returns the same source the
//!   browser uses, with FLAT keys: `HTTPEnable`/`HTTPProxy`/`HTTPPort` and the
//!   `HTTPS*`/`SOCKS*` triple live at the top level (verified against a live
//!   Clash setup), not nested per-protocol dictionaries.
//! * iOS: that API is deprecated there and answers with nothing, so the proxy
//!   is asked for per target URL via `CFNetworkCopyProxiesForURL`. This is the
//!   same resolution URLSession performs, and it is the only way to see a
//!   proxy that a VPN client configured through `NEProxySettings`.
//!
//! A Network Extension in transparent-tunnel mode installs no proxy at all;
//! raw sockets already go through it, so returning `None` there is correct.

use core_foundation_sys::base::{CFGetTypeID, CFIndex, CFRelease, CFTypeID, CFTypeRef};
use core_foundation_sys::dictionary::{CFDictionaryGetValue, CFDictionaryRef};
use core_foundation_sys::number::{
    kCFNumberSInt64Type, CFNumberGetTypeID, CFNumberGetValue, CFNumberRef,
};
use core_foundation_sys::string::{
    __CFString, kCFStringEncodingUTF8, CFStringGetCString, CFStringGetLength, CFStringGetTypeID,
    CFStringRef,
};
use std::ffi::{c_char, c_void};
use std::ptr;

#[cfg(target_os = "macos")]
extern "C" {
    fn CFNetworkCopySystemProxySettings() -> CFDictionaryRef;
}

#[cfg(target_os = "ios")]
extern "C" {
    fn CFNetworkCopyProxiesForURL(
        url: core_foundation_sys::url::CFURLRef,
        proxy_settings: CFDictionaryRef,
    ) -> core_foundation_sys::array::CFArrayRef;
    static kCFProxyTypeKey: CFStringRef;
    static kCFProxyHostNameKey: CFStringRef;
    static kCFProxyPortNumberKey: CFStringRef;
    static kCFProxyTypeNone: CFStringRef;
    static kCFProxyTypeHTTP: CFStringRef;
    static kCFProxyTypeHTTPS: CFStringRef;
}

#[link(name = "CFNetwork", kind = "framework")]
extern "C" {}

/// The system HTTP(S) proxy as `http://host:port`.
///
/// SOCKS and PAC configurations are reported as `None`: the shared HTTP client
/// only speaks an HTTP proxy, and resolving a PAC script would need a run loop
/// on a background thread. A transparent tunnel needs no entry here at all.
pub fn system_proxy() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        macos_system_proxy()
    }
    #[cfg(target_os = "ios")]
    {
        ios_url_proxy()
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn macos_system_proxy() -> Option<String> {
    // Create-rule result: we own one reference and release it at scope end.
    let settings = unsafe { CFNetworkCopySystemProxySettings() };
    if settings.is_null() {
        return None;
    }
    let read = |protocol: &'static str| -> Option<(String, i64)> {
        // Flat keys: HTTPSProxy/HTTPSPort/HTTPSEnable hold the host/port and a
        // numeric on-switch directly in the returned dictionary.
        if number_value(settings, &format!("{protocol}Enable"))? != 1 {
            return None;
        }
        let host = string_value(settings, &format!("{protocol}Proxy"))?;
        let port = number_value(settings, &format!("{protocol}Port"))?;
        Some((host, port))
    };
    let proxy = read("HTTPS").or_else(|| read("HTTP"));
    unsafe { CFRelease(settings as *mut c_void) };
    proxy_url(proxy?)
}

/// iOS resolves proxies per target URL, so ask about the host the app actually
/// calls. Proxy configuration is normally global; a PAC that differs per host
/// is reported as `None` rather than guessed.
#[cfg(target_os = "ios")]
fn ios_url_proxy() -> Option<String> {
    let url = CFString::new("https://api.bgm.tv/v0/subjects/1");
    if url.0.is_null() {
        return None;
    }
    let url =
        unsafe { core_foundation_sys::url::CFURLCreateWithString(ptr::null(), url.0, ptr::null()) };
    if url.is_null() {
        return None;
    }
    // A null settings dictionary asks CFNetwork for the current system state.
    let proxies = unsafe { CFNetworkCopyProxiesForURL(url, ptr::null()) };
    unsafe { CFRelease(url as *mut c_void) };
    if proxies.is_null() {
        return None;
    }
    let result = unsafe { read_proxy_list(proxies) };
    unsafe { CFRelease(proxies as *mut c_void) };
    result
}

/// Walk the array `CFNetworkCopyProxiesForURL` returns and take the first
/// HTTP(S) entry. The array always holds at least one element; a single
/// `kCFProxyTypeNone` element means "connect directly".
#[cfg(target_os = "ios")]
unsafe fn read_proxy_list(proxies: core_foundation_sys::array::CFArrayRef) -> Option<String> {
    use core_foundation_sys::array::{CFArrayGetCount, CFArrayGetValueAtIndex};
    use core_foundation_sys::base::CFEqual;

    let count = CFArrayGetCount(proxies);
    for index in 0..count {
        let entry = CFArrayGetValueAtIndex(proxies, index) as CFDictionaryRef;
        if entry.is_null() {
            continue;
        }
        // Compare the borrowed CFString directly: the proxy-type constants are
        // CFStringRef values, so converting to a Rust String would lose them.
        let kind = string_ref_for_key(entry, kCFProxyTypeKey);
        let Some(kind) = kind else { continue };
        if CFEqual(kind as CFTypeRef, kCFProxyTypeNone as CFTypeRef) != 0 {
            return None;
        }
        let is_http = CFEqual(kind as CFTypeRef, kCFProxyTypeHTTP as CFTypeRef) != 0
            || CFEqual(kind as CFTypeRef, kCFProxyTypeHTTPS as CFTypeRef) != 0;
        if !is_http {
            // SOCKS and PAC entries cannot be expressed to the shared client.
            continue;
        }
        let host = string_value_for_key(entry, kCFProxyHostNameKey)?;
        let port = number_value_for_key(entry, kCFProxyPortNumberKey)?;
        return proxy_url((host, port));
    }
    None
}

/// Build the proxy URL, rejecting values CFNetwork should never produce but
/// that would otherwise become an unusable `http://host:-1` downstream.
fn proxy_url((host, port): (String, i64)) -> Option<String> {
    if host.is_empty() || !(1..=65535).contains(&port) {
        return None;
    }
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!("http://{host}:{port}"))
}

#[cfg(target_os = "macos")]
fn string_value(dict: CFDictionaryRef, key: &str) -> Option<String> {
    let key = CFString::new(key);
    if key.0.is_null() {
        return None;
    }
    string_value_for_key(dict, key.0)
}

/// Read a string value by an already-created CFString key, so callers holding a
/// CFNetwork constant do not have to rebuild it. The borrowed CFString itself
/// is returned; it stays owned by the dictionary.
#[cfg(target_os = "ios")]
fn string_ref_for_key(dict: CFDictionaryRef, key: CFStringRef) -> Option<CFStringRef> {
    if key.is_null() {
        return None;
    }
    let value = unsafe { CFDictionaryGetValue(dict, key as *const c_void) };
    if value.is_null() {
        return None;
    }
    let string_type: CFTypeID = unsafe { CFStringGetTypeID() };
    let type_id: CFTypeID = unsafe { CFGetTypeID(value as CFTypeRef) };
    if type_id != string_type {
        return None;
    }
    Some(value as CFStringRef)
}

/// Read a string value by an already-created CFString key, so callers holding a
/// CFNetwork constant do not have to rebuild it.
fn string_value_for_key(dict: CFDictionaryRef, key: CFStringRef) -> Option<String> {
    if key.is_null() {
        return None;
    }
    let value = unsafe { CFDictionaryGetValue(dict, key as *const c_void) };
    if value.is_null() {
        return None;
    }
    // The dictionary holds mixed types; CFStringGetLength on a non-string is
    // undefined behaviour, so check the type exactly like number_value does.
    let string_type: CFTypeID = unsafe { CFStringGetTypeID() };
    let type_id: CFTypeID = unsafe { CFGetTypeID(value as CFTypeRef) };
    if type_id != string_type {
        return None;
    }
    let string = value as CFStringRef;
    let length = unsafe { CFStringGetLength(string) };
    let mut buffer = vec![0 as c_char; (length + 1) as usize * 4];
    let ok = unsafe {
        CFStringGetCString(
            string,
            buffer.as_mut_ptr(),
            buffer.len() as CFIndex,
            kCFStringEncodingUTF8,
        )
    };
    if ok == 0 {
        return None;
    }
    let text = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) };
    Some(text.to_string_lossy().into_owned())
}

#[cfg(target_os = "macos")]
fn number_value(dict: CFDictionaryRef, key: &str) -> Option<i64> {
    let key = CFString::new(key);
    if key.0.is_null() {
        return None;
    }
    number_value_for_key(dict, key.0)
}

fn number_value_for_key(dict: CFDictionaryRef, key: CFStringRef) -> Option<i64> {
    if key.is_null() {
        return None;
    }
    let value = unsafe { CFDictionaryGetValue(dict, key as *const c_void) };
    if value.is_null() {
        return None;
    }
    // The dictionary also carries strings and booleans; calling
    // CFNumberGetValue on those raises an NSException, so check the type first.
    let number_type: CFTypeID = unsafe { CFNumberGetTypeID() };
    let type_id: CFTypeID = unsafe { CFGetTypeID(value as CFTypeRef) };
    if type_id != number_type {
        return None;
    }
    let mut out: i64 = 0;
    let ok = unsafe {
        CFNumberGetValue(
            value as CFNumberRef,
            kCFNumberSInt64Type,
            &mut out as *mut i64 as *mut c_void,
        )
    };
    if !ok {
        return None;
    }
    Some(out)
}

/// A create-rule CFString that releases itself on drop.
struct CFString(*const __CFString);

impl CFString {
    fn new(text: &str) -> Self {
        // core_foundation_sys does not re-export the create call as a safe
        // helper with our MSRV-aligned feature set; declare the FFI locally.
        // CFStringCreateWithBytes takes an explicit length, so a Rust &str
        // needs no NUL terminator (passing one to the C-string variant read
        // past the allocation).
        extern "C" {
            fn CFStringCreateWithBytes(
                alloc: *mut c_void,
                bytes: *const u8,
                num_bytes: CFIndex,
                encoding: u32,
                is_external_representation: bool,
            ) -> CFStringRef;
        }
        let created = unsafe {
            CFStringCreateWithBytes(
                ptr::null_mut(),
                text.as_ptr(),
                text.len() as CFIndex,
                kCFStringEncodingUTF8 as u32,
                false,
            )
        };
        CFString(created)
    }
}

impl Drop for CFString {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0 as *mut c_void) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{proxy_url, system_proxy};

    #[test]
    fn proxy_url_rejects_unusable_values() {
        assert_eq!(proxy_url((String::new(), 7890)), None);
        assert_eq!(proxy_url(("127.0.0.1".into(), 0)), None);
        assert_eq!(proxy_url(("127.0.0.1".into(), 65536)), None);
        assert_eq!(
            proxy_url(("127.0.0.1".into(), 7890)).as_deref(),
            Some("http://127.0.0.1:7890")
        );
        // A bare IPv6 host must be bracketed, an already-bracketed one kept.
        assert_eq!(
            proxy_url(("::1".into(), 7890)).as_deref(),
            Some("http://[::1]:7890")
        );
        assert_eq!(
            proxy_url(("[::1]".into(), 7890)).as_deref(),
            Some("http://[::1]:7890")
        );
    }

    /// On the dev machine (Clash at 127.0.0.1:7890) this must find the proxy;
    /// on any machine with no manual HTTP proxy it legitimately returns None.
    #[test]
    fn reads_live_system_proxy_without_crashing() {
        let result = system_proxy();
        let enabled = std::env::var("HTTPS_PROXY").ok().filter(|v| !v.is_empty());
        match (result, enabled) {
            (None, None) => {}
            (None, Some(_)) => panic!("system proxy env is set but CFNetwork lookup returned None"),
            (Some(proxy), _) => {
                assert!(proxy.starts_with("http://"));
                assert!(!proxy.ends_with(':'));
            }
        }
    }
}
