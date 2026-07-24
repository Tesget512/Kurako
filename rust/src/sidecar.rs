//! Per-folder ".kurako-match.json" sidecar files that record manual Bangumi
//! matches next to the media they describe. Unlike a single DB column or a
//! central JSON in the data folder, a sidecar lives IN the media folder, so a
//! manual match survives ANY rescan — including "清空并重新扫描", which drops the
//! whole episodes table — and travels with the files if the library is moved to
//! another machine.
//!
//! Layout: one sidecar per folder, a JSON object mapping video FILE NAME ->
//! bangumi_id. A value of `0` (`DETACHED`) means the file was pulled out of its
//! mis-grouped show into 未分类 and must stay out. Sidecars are written ONLY when
//! the user manually matches or detaches — never for auto-matches — so folders
//! the user never corrected stay clean. They are read at the tail of every scan
//! to re-route each listed file onto its chosen subject regardless of how the
//! scanner grouped it by filename.
//!
//! This module holds only the pure/local pieces (path math, JSON, local FS I/O);
//! SMB read/write goes through `smb.rs`, and SAF (content:// on Android) can't be
//! written from Rust so it's handled as unsupported by the caller.

use std::collections::BTreeMap;
use std::path::Path;

use once_cell::sync::OnceCell;
use std::path::PathBuf;
use std::sync::Mutex;

/// The sidecar file name placed in each manually-corrected media folder.
pub const SIDECAR_NAME: &str = ".kurako-match.json";
/// Sentinel bangumi id meaning "detached to 未分类, keep out of any show".
pub const DETACHED: i64 = 0;

/// The app data directory (where the SQLite DB lives), set once at DB init. The
/// fallback config file lives here for sources whose media folder can't hold a
/// sidecar (read-only SMB, Android SAF).
static DATA_DIR: OnceCell<PathBuf> = OnceCell::new();
/// Serializes read-modify-write of the fallback file.
static FALLBACK_LOCK: Mutex<()> = Mutex::new(());
/// The fallback config file name in the data directory.
const FALLBACK_NAME: &str = "match_fallback.json";

/// file_name -> bangumi_id map stored in one folder's sidecar.
pub type SidecarMap = BTreeMap<String, i64>;

/// The three ways a library file's location is addressed, inferred from the
/// locator scheme, since each needs different sidecar I/O.
pub enum Source {
    Local,
    Smb,
    /// Android Storage Access Framework (content:// tree) — Rust can't write
    /// files there, so its sidecar persistence is unsupported.
    Saf,
}

pub fn source_of(locator: &str) -> Source {
    if locator.starts_with("smb://") {
        Source::Smb
    } else if locator.starts_with("content://") {
        Source::Saf
    } else {
        Source::Local
    }
}

/// Split a locator into (parent_folder, file_name). Handles both native local
/// paths (`D:\a\b\ep.mkv`) and forward-slash URIs (`smb://h/s/dir/ep.mkv`) by
/// cutting at the last separator of either kind.
pub fn split_parent_name(locator: &str) -> Option<(String, String)> {
    let idx = locator.rfind(['/', '\\'])?;
    let parent = &locator[..idx];
    let name = &locator[idx + 1..];
    if name.is_empty() {
        return None;
    }
    Some((parent.to_string(), name.to_string()))
}

/// The sidecar's own locator, given its parent folder locator. Local uses the
/// native separator; smb/saf use '/'.
pub fn sidecar_locator(parent: &str) -> String {
    match source_of(parent) {
        Source::Local => Path::new(parent)
            .join(SIDECAR_NAME)
            .to_string_lossy()
            .to_string(),
        _ => format!("{parent}/{SIDECAR_NAME}"),
    }
}

pub fn parse(bytes: &[u8]) -> SidecarMap {
    serde_json::from_slice(bytes).unwrap_or_default()
}

pub fn serialize(map: &SidecarMap) -> Vec<u8> {
    serde_json::to_vec_pretty(map).unwrap_or_default()
}

/// Read a local folder's sidecar map (empty if absent/unreadable/corrupt — a
/// bad sidecar must never block a scan).
pub fn read_local(parent: &str) -> SidecarMap {
    let p = Path::new(parent).join(SIDECAR_NAME);
    match std::fs::read(p) {
        Ok(bytes) => parse(&bytes),
        Err(_) => SidecarMap::new(),
    }
}

/// Write a local folder's sidecar. If the resulting map is empty, remove the
/// file instead of leaving an empty `{}` behind.
pub fn write_local(parent: &str, map: &SidecarMap) -> anyhow::Result<()> {
    let p = Path::new(parent).join(SIDECAR_NAME);
    if map.is_empty() {
        let _ = std::fs::remove_file(&p);
        return Ok(());
    }
    std::fs::write(&p, serialize(map))?;
    Ok(())
}

// ---- Fallback store (app data directory) ----
//
// For sources whose media folder can't hold a sidecar — a read-only SMB share,
// or Android SAF (Rust can't write content:// files) — the manual match is kept
// in a single `match_fallback.json` in the app data directory instead. Unlike
// the per-folder sidecars (keyed by bare file name), this is keyed by the FULL
// file locator, since one flat file covers every folder. Read at every scan tail
// so these matches survive a rescan just like real sidecars do.

/// Record where the app data directory is (the SQLite DB's parent), so the
/// fallback file can be located. Called once at `init_db`.
pub fn set_data_dir_from_db(db_path: &str) {
    let dir = Path::new(db_path)
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_default();
    let _ = DATA_DIR.set(dir);
}

fn fallback_path() -> Option<PathBuf> {
    DATA_DIR.get().map(|d| d.join(FALLBACK_NAME))
}

/// The fallback map (full file locator -> bangumi_id), empty if absent/corrupt.
pub fn read_fallback() -> BTreeMap<String, i64> {
    let Some(p) = fallback_path() else {
        return BTreeMap::new();
    };
    match std::fs::read(&p) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => BTreeMap::new(),
    }
}

/// Record one file's manual match in the fallback store and persist it. Returns
/// an error only if the data dir isn't set or the write fails — the data dir is
/// always local and writable, so this is the reliable "always works" path.
pub fn set_fallback(file_path: &str, bangumi_id: i64) -> anyhow::Result<()> {
    let _guard = FALLBACK_LOCK.lock().unwrap();
    let p = fallback_path().ok_or_else(|| anyhow::anyhow!("data dir not set"))?;
    let mut map = read_fallback();
    map.insert(file_path.to_string(), bangumi_id);
    std::fs::write(&p, serde_json::to_vec_pretty(&map)?)?;
    Ok(())
}

/// Delete the entire fallback store. Returns whether a file was removed.
pub fn remove_all_fallback() -> bool {
    let _guard = FALLBACK_LOCK.lock().unwrap();
    let Some(p) = fallback_path() else {
        return false;
    };
    std::fs::remove_file(&p).is_ok()
}
