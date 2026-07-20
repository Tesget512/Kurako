//! SMB2/3 network-share client, built on the pure-Rust `smb2` crate.
//!
//! A share is added as a library folder with `source_type = "smb"` and a path
//! like `smb://host[:port]/share/subdir`. Credentials are cached process-wide
//! after a successful connect. Enumeration lists the tree into `ScannedFile`s
//! (reusing the same recognition/grouping as local + SAF). Playback is served
//! through a local HTTP proxy (see the `proxy` section) because libmpv's bundled
//! FFmpeg usually lacks the `smb://` protocol.

use crate::models::ScannedFile;
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use std::sync::Mutex;

const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "m2ts", "rmvb", "rm", "mpg",
    "mpeg", "3gp", "ogv",
];

/// Cached SMB credentials. `smb2::Client` holds a live TCP connection that isn't
/// convenient to keep across separate `block_on` calls, so we cache the login
/// details and open a fresh connection per operation instead.
#[derive(Clone)]
pub struct SmbCreds {
    /// "host:port" (445 assumed if the user omits the port).
    pub addr: String,
    pub share: String,
    pub user: String,
    pub password: String,
}

static CREDS: Lazy<Mutex<Option<SmbCreds>>> = Lazy::new(|| Mutex::new(None));

pub fn creds() -> Option<SmbCreds> {
    CREDS.lock().unwrap().clone()
}

pub fn set_creds(c: Option<SmbCreds>) {
    *CREDS.lock().unwrap() = c;
}

fn is_video(name: &str) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => VIDEO_EXTS.contains(&ext.to_ascii_lowercase().as_str()),
        None => false,
    }
}

/// Normalize a user-entered host into "host:port" (default SMB port 445).
fn normalize_addr(host: &str) -> String {
    let h = host.trim();
    if h.contains(':') {
        h.to_string()
    } else {
        format!("{h}:445")
    }
}

/// Open a client + connect the share using the given credentials.
async fn open(c: &SmbCreds) -> Result<(smb2::SmbClient, smb2::Tree)> {
    let mut client = smb2::connect(&c.addr, &c.user, &c.password)
        .await
        .context("smb connect")?;
    let tree = client
        .connect_share(&c.share)
        .await
        .context("smb connect_share")?;
    Ok((client, tree))
}

/// Test-connect with the given credentials and cache them on success.
pub async fn connect(host: &str, share: &str, user: &str, password: &str) -> Result<()> {
    let c = SmbCreds {
        addr: normalize_addr(host),
        share: share.trim().trim_matches('/').to_string(),
        user: user.to_string(),
        password: password.to_string(),
    };
    let (mut client, mut tree) = open(&c).await?;
    // A root listing proves auth + share access work.
    let _ = client.list_directory(&mut tree, "").await;
    set_creds(Some(c));
    Ok(())
}

/// Recursively enumerate video files under `subdir` (relative to the share
/// root, "" = whole share). Produces `ScannedFile`s whose `uri` is the full
/// `smb://host/share/path` and `relative_parent` is the folder path from
/// `subdir`, so grouping matches the local/SAF behaviour.
pub async fn enumerate(subdir: &str) -> Result<Vec<ScannedFile>> {
    let c = creds().context("smb not connected")?;
    let (mut client, mut tree) = open(&c).await?;
    let mut out = Vec::new();
    let base = subdir.trim_matches('/').to_string();
    walk(&mut client, &mut tree, &c, &base, "", &mut out).await?;
    let _ = client.disconnect_share(&tree).await;
    Ok(out)
}

/// Depth-first walk. `smb_path` is the path on the share; `rel` is the path
/// relative to the enumerate root (for grouping).
async fn walk(
    client: &mut smb2::SmbClient,
    tree: &mut smb2::Tree,
    creds: &SmbCreds,
    smb_path: &str,
    rel: &str,
    out: &mut Vec<ScannedFile>,
) -> Result<()> {
    let entries = client
        .list_directory(tree, smb_path)
        .await
        .with_context(|| format!("smb list {smb_path}"))?;
    for e in entries {
        if e.name == "." || e.name == ".." {
            continue;
        }
        let child_smb = if smb_path.is_empty() {
            e.name.clone()
        } else {
            format!("{smb_path}/{}", e.name)
        };
        let child_rel = if rel.is_empty() {
            e.name.clone()
        } else {
            format!("{rel}/{}", e.name)
        };
        if e.is_directory {
            Box::pin(walk(client, tree, creds, &child_smb, &child_rel, out)).await?;
        } else if is_video(&e.name) {
            // Parent folder of this file, relative to the enumerate root.
            let parent = child_rel
                .rsplit_once('/')
                .map(|(p, _)| p.to_string())
                .unwrap_or_default();
            out.push(ScannedFile {
                uri: format!("smb://{}/{}/{}", creds.addr, creds.share, child_smb),
                file_name: e.name.clone(),
                relative_parent: parent,
            });
        }
    }
    Ok(())
}

/// Parse an `smb://host:port/share/path...` URI back into (share_relative_path).
/// Returns the path on the share (what smb2 wants), given the cached creds.
pub fn smb_path_from_uri(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("smb://")?;
    // rest = host:port/share/path...
    let mut parts = rest.splitn(3, '/');
    let _host = parts.next()?;
    let _share = parts.next()?;
    Some(parts.next().unwrap_or("").to_string())
}
