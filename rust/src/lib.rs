pub mod api;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub mod apple_proxy;
pub mod bangumi;
pub mod db;
pub mod discovery;
pub mod duplicate_check;
mod frb_generated;
pub mod local_proxy;
pub mod models;
pub mod recognize;
pub mod scan;
pub mod scan_control;
pub mod sidecar;
pub mod smb;
pub mod subtitle;
#[cfg(test)]
pub(crate) mod test_http;
pub mod update;
pub mod watch_history;
pub mod webdav;
