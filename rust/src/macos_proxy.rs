//! macOS system HTTP proxy lookup via CFNetwork.
//!
//! GUI-launched apps do not inherit shell proxy environment variables, so the
//! env-var fallback in `detect_system_proxy` never sees the user's Clash/proxy
//! setup. `CFNetworkCopySystemProxySettings` returns the same source the
//! browser uses, with FLAT keys: `HTTPEnable`/`HTTPProxy`/`HTTPPort` and the
//! `HTTPS*`/`SOCKS*` triple live at the top level (verified against a live
//! Clash setup), not nested per-protocol dictionaries. Reading it keeps
//! authorization-page traffic and our token requests on one network route.

use core_foundation_sys::base::{CFGetTypeID, CFIndex, CFRelease, CFTypeID, CFTypeRef};
use core_foundation_sys::dictionary::{CFDictionaryGetValue, CFDictionaryRef};
use core_foundation_sys::number::{
    kCFNumberSInt64Type, CFNumberGetTypeID, CFNumberGetValue, CFNumberRef,
};
use core_foundation_sys::string::{
    __CFString, kCFStringEncodingUTF8, CFStringGetCString, CFStringGetLength, CFStringRef,
};
use std::ffi::{c_char, c_void};
use std::ptr;

extern "C" {
    fn CFNetworkCopySystemProxySettings() -> CFDictionaryRef;
}

#[link(name = "CFNetwork", kind = "framework")]
extern "C" {}

/// The macOS HTTP(S) proxy as `http://host:port`, preferring HTTPS over HTTP.
pub fn system_proxy() -> Option<String> {
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
    let (host, port) = proxy?;
    if host.is_empty() || port == 0 {
        return None;
    }
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!("http://{host}:{port}"))
}

fn string_value(dict: CFDictionaryRef, key: &str) -> Option<String> {
    let key = CFString::new(key);
    let value = unsafe { CFDictionaryGetValue(dict, key.as_CFTypeRef() as *const c_void) };
    if value.is_null() {
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

fn number_value(dict: CFDictionaryRef, key: &str) -> Option<i64> {
    let key = CFString::new(key);
    let value = unsafe { CFDictionaryGetValue(dict, key.as_CFTypeRef() as *const c_void) };
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
        extern "C" {
            fn CFStringCreateWithCString(
                alloc: *mut c_void,
                c_str: *const c_char,
                encoding: u32,
            ) -> CFStringRef;
        }
        let created = unsafe {
            CFStringCreateWithCString(
                ptr::null_mut(),
                text.as_ptr() as *const c_char,
                kCFStringEncodingUTF8 as u32,
            )
        };
        CFString(created)
    }

    #[allow(non_snake_case)]
    fn as_CFTypeRef(&self) -> CFTypeRef {
        self.0 as CFTypeRef
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
    use super::system_proxy;

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
