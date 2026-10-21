pub mod api;
pub mod bangumi;
pub mod db;
pub mod discovery;
pub mod duplicate_check;
mod frb_generated;
pub mod local_proxy;
#[cfg(target_os = "macos")]
pub mod macos_proxy;
pub mod models;
pub mod recognize;
pub mod scan;
pub mod scan_control;
pub mod sidecar;
pub mod smb;
pub mod subtitle;
pub mod update;
pub mod webdav;
