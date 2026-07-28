//! SMB2/3 network-share client, built on the pure-Rust `smb2` crate.
//!
//! A share is added as a library folder with `source_type = "smb"` and a path
//! like `smb://host[:port]/share/subdir`. Credentials are cached process-wide
//! after a successful connect. Enumeration lists the tree into `ScannedFile`s
//! (reusing the same recognition/grouping as local + SAF). Playback is served
//! through a local HTTP proxy (see the `proxy` section) because libmpv's bundled
//! FFmpeg usually lacks the `smb://` protocol.

use crate::models::{RemoteDirectory, ScannedFile, SmbShareInfo};
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU16, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "m2ts", "rmvb", "rm", "mpg",
    "mpeg", "3gp", "ogv",
];

pub const DOWNLOADED_SUBTITLE_DIR: &str = "Subtitles";

/// Cap every SMB *setup* step (TCP connect, share connect, file open) so a NAS
/// that has hit its per-client session limit — or is briefly unresponsive —
/// can't hang the call forever. This is the cross-folder freeze: switching to a
/// video in a different folder opens fresh connections while the old ones are
/// still draining; if the server refuses the new session the connect blocks
/// indefinitely and the player spins on "loading". A bounded connect turns that
/// into a clean, recoverable failure instead of a deadlock.
const SETUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);

/// Windows may silently discard an idle mobile SMB connection while the app is
/// in the background.  Do not wait for that stale connection's full request
/// timeout on the next user action: when no proxy stream is active, establish a
/// fresh session after this quiet period.  Continuous playback, downloads and
/// scans keep using the same multiplexed session as before.
const IDLE_SESSION_RECONNECT_AFTER: std::time::Duration = std::time::Duration::from_secs(60);

/// Cached SMB credentials, used to establish the shared connection on startup
/// and after a genuine network failure.
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
    // Credentials changed (reconnect/reconfigure) — drop any persistent proxy
    // session so the next stream reconnects under the current creds instead of
    // reusing one tied to the old (possibly now-invalid) ones.
    invalidate_session();
}

/// A single authenticated connection is shared by library scans, sidecar I/O,
/// downloads and the loopback player. `smb2` multiplexes requests safely on a
/// connection; the async mutex is only needed for APIs such as directory walks
/// that require mutable client/tree access.
struct SmbSessionInner {
    client: smb2::SmbClient,
    tree: smb2::Tree,
}

struct SmbSession {
    inner: tokio::sync::Mutex<SmbSessionInner>,
    last_activity: Mutex<Instant>,
}

impl SmbSession {
    fn new(client: smb2::SmbClient, tree: smb2::Tree) -> Self {
        Self {
            inner: tokio::sync::Mutex::new(SmbSessionInner { client, tree }),
            last_activity: Mutex::new(Instant::now()),
        }
    }

    fn touch(&self) {
        *self.last_activity.lock().unwrap() = Instant::now();
    }

    fn has_been_idle_too_long(&self) -> bool {
        self.last_activity.lock().unwrap().elapsed() >= IDLE_SESSION_RECONNECT_AFTER
    }
}

static SESSION: Mutex<Option<std::sync::Arc<SmbSession>>> = Mutex::new(None);
/// Serializes session (re)establishment so concurrent first operations pay for
/// one handshake rather than racing to create several Windows SMB sessions.
static SESSION_INIT: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

#[derive(Clone)]
struct SetupSession {
    creds: SmbCreds,
    session: std::sync::Arc<SmbSession>,
}

/// Setup/browser sessions are intentionally separate from the active playback
/// session. Looking at a discovered server or cancelling the wizard must never
/// replace credentials underneath an ongoing scan or video.
static SETUP_SESSIONS: Lazy<Mutex<HashMap<String, SetupSession>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_SETUP_ID: AtomicU64 = AtomicU64::new(1);

fn cache_session(c: SmbCreds, client: smb2::SmbClient, tree: smb2::Tree) {
    *CREDS.lock().unwrap() = Some(c);
    *SESSION.lock().unwrap() = Some(std::sync::Arc::new(SmbSession::new(client, tree)));
}

/// The `smb://addr/share/subdir/` URI prefix that enumerated files under
/// `subdir` share, built from the cached creds (so it matches the `addr:port`
/// form stored on episodes, unlike a user-entered host). Used to scope
/// deletion-pruning of a network folder. Returns None if not connected.
pub fn uri_prefix(subdir: &str) -> Option<String> {
    let c = creds()?;
    let sub = subdir.trim_matches('/');
    if sub.is_empty() {
        Some(format!("smb://{}/{}/", c.addr, c.share))
    } else {
        Some(format!("smb://{}/{}/{}/", c.addr, c.share, sub))
    }
}

pub fn is_video(name: &str) -> bool {
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
    let mut client =
        tokio::time::timeout(SETUP_TIMEOUT, smb2::connect(&c.addr, &c.user, &c.password))
            .await
            .context("smb connect timed out")?
            .context("smb connect")?;
    let tree = tokio::time::timeout(SETUP_TIMEOUT, client.connect_share(&c.share))
        .await
        .context("smb connect_share timed out")?
        .context("smb connect_share")?;
    Ok((client, tree))
}

/// Test-connect with the given credentials and retain that exact connection.
///
/// Windows was rejecting playback immediately after a scan because validation,
/// scanning and playback each created a separate authenticated session. Keeping
/// the verified session makes all three phases use one server-side session.
pub async fn connect(host: &str, share: &str, user: &str, password: &str) -> Result<()> {
    let c = SmbCreds {
        addr: normalize_addr(host),
        share: share.trim().trim_matches('/').to_string(),
        user: user.to_string(),
        password: password.to_string(),
    };
    // This is an explicit reconnect/reconfiguration request. Do not let a
    // previous timed-out server session remain the process-wide default while
    // validation is trying to establish the new one.
    invalidate_session();
    // A busy SMB server can briefly reject a second session while it reaps an
    // old one. Retrying this *initial* connection once avoids presenting the
    // cryptic bare "smb connect" error after a player/download was just
    // stopped, without leaving the UI blocked indefinitely.
    let mut last_error = None;
    for attempt in 0..2 {
        match open(&c).await {
            Ok((mut client, mut tree)) => {
                // A root listing proves auth + share access work. Keep the
                // connected tree on success instead of TreeDisconnect-ing it.
                let listed =
                    tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(&mut tree, "")).await;
                match listed {
                    Ok(Ok(_)) => {
                        cache_session(c, client, tree);
                        return Ok(());
                    }
                    Ok(Err(error)) => last_error = Some(error.into()),
                    Err(_) => {
                        last_error = Some(anyhow::anyhow!("smb root listing timed out"));
                    }
                }
            }
            Err(e) => last_error = Some(e),
        }
        if attempt == 0 {
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("smb connect failed")))
}

/// List disk shares through a short-lived IPC$ connection. NAS devices may
/// disable srvsvc; callers must retain a manual share-name fallback.
pub async fn list_shares(host: &str, user: &str, password: &str) -> Result<Vec<SmbShareInfo>> {
    let addr = normalize_addr(host);
    let mut client = tokio::time::timeout(SETUP_TIMEOUT, smb2::connect(&addr, user, password))
        .await
        .context("smb connect timed out")?
        .context("smb connect")?;
    let shares = tokio::time::timeout(SETUP_TIMEOUT, client.list_shares())
        .await
        .context("smb share listing timed out")?
        .context("smb share listing")?;
    let mut shares: Vec<_> = shares
        .into_iter()
        .map(|share| SmbShareInfo {
            name: share.name,
            comment: share.comment,
        })
        .collect();
    shares.sort_by_key(|share| share.name.to_lowercase());
    Ok(shares)
}

/// Open one isolated share browser and return an opaque token. The connection
/// is only promoted to the active SMB session after the user confirms folders.
pub async fn setup_begin(host: &str, share: &str, user: &str, password: &str) -> Result<String> {
    let creds = SmbCreds {
        addr: normalize_addr(host),
        share: share.trim().trim_matches('/').to_string(),
        user: user.to_string(),
        password: password.to_string(),
    };
    if creds.share.is_empty() {
        anyhow::bail!("SMB share name is empty");
    }
    let (mut client, mut tree) = open(&creds).await?;
    tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(&mut tree, ""))
        .await
        .context("smb root listing timed out")?
        .context("smb root listing")?;
    let token = format!(
        "setup-{}-{}",
        std::process::id(),
        NEXT_SETUP_ID.fetch_add(1, Ordering::Relaxed)
    );
    let setup = SetupSession {
        creds,
        session: std::sync::Arc::new(SmbSession::new(client, tree)),
    };
    let mut sessions = SETUP_SESSIONS.lock().unwrap();
    // A user can only have one visible wizard. Clear abandoned setup sessions
    // defensively so repeated opens never accumulate SMB server sessions.
    sessions.clear();
    sessions.insert(token.clone(), setup);
    Ok(token)
}

pub async fn setup_list_directories(token: &str, subdir: &str) -> Result<Vec<RemoteDirectory>> {
    let setup = SETUP_SESSIONS
        .lock()
        .unwrap()
        .get(token)
        .cloned()
        .context("SMB setup session has expired")?;
    let path = subdir.trim_matches('/').to_string();
    let mut guard = tokio::time::timeout(SETUP_TIMEOUT, setup.session.inner.lock())
        .await
        .context("smb setup session remained busy for too long")?;
    let entries = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(tree, &path))
            .await
            .context("smb directory listing timed out")?
            .context("smb directory listing")?
    };
    drop(guard);
    setup.session.touch();
    let mut directories: Vec<_> = entries
        .into_iter()
        .filter(|entry| entry.is_directory && entry.name != "." && entry.name != "..")
        .map(|entry| RemoteDirectory {
            path: if path.is_empty() {
                entry.name.clone()
            } else {
                format!("{path}/{}", entry.name)
            },
            name: entry.name,
        })
        .collect();
    directories.sort_by_key(|directory| directory.name.to_lowercase());
    Ok(directories)
}

pub fn setup_cancel(token: &str) {
    SETUP_SESSIONS.lock().unwrap().remove(token);
}

/// Promote the already-validated setup connection atomically. Refuse to swap
/// the active share while a proxy stream or download is using it.
pub fn setup_commit(token: &str) -> Result<()> {
    if !ACTIVE_STREAMS.lock().unwrap().is_empty() || SMB_DL_CONN.available_permits() == 0 {
        anyhow::bail!("SMB 正在播放或下载，请结束后再更换网络共享");
    }
    let setup = SETUP_SESSIONS
        .lock()
        .unwrap()
        .remove(token)
        .context("SMB setup session has expired")?;
    *CREDS.lock().unwrap() = Some(setup.creds);
    *SESSION.lock().unwrap() = Some(setup.session);
    Ok(())
}

/// Recursively enumerate video files under `subdir` (relative to the share
/// root, "" = whole share). Produces `ScannedFile`s whose `uri` is the full
/// `smb://host/share/path` and `relative_parent` is the folder path from
/// `subdir`, so grouping matches the local/SAF behaviour.
pub async fn enumerate(subdir: &str) -> Result<Vec<ScannedFile>> {
    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let mut out = Vec::new();
    let base = subdir.trim_matches('/').to_string();
    walk(&session, &c, &base, "", &mut out).await?;
    Ok(out)
}

/// Depth-first walk. `smb_path` is the path on the share; `rel` is the path
/// relative to the enumerate root (for grouping).
async fn walk(
    session: &std::sync::Arc<SmbSession>,
    creds: &SmbCreds,
    smb_path: &str,
    rel: &str,
    out: &mut Vec<ScannedFile>,
) -> Result<()> {
    // Do not hold the session mutex over the entire recursive scan. A single
    // folder request may stall after Wi-Fi sleep or an SMB server timeout; if
    // that used to happen mid-walk, every later playback/refresh queued behind
    // this one lock forever even after the UI abandoned the original Future.
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session_if(session);
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let entries = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(tree, smb_path)).await
    };
    let entries = match entries {
        Ok(Ok(entries)) => {
            session.touch();
            entries
        }
        Ok(Err(error)) => {
            drop(guard);
            invalidate_session_if(session);
            return Err(error).with_context(|| format!("smb list {smb_path}"));
        }
        Err(_) => {
            drop(guard);
            invalidate_session_if(session);
            anyhow::bail!("smb list {smb_path} timed out")
        }
    };
    drop(guard);
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
            Box::pin(walk(session, creds, &child_smb, &child_rel, out)).await?;
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

#[derive(Debug)]
struct SmbSubtitleFile {
    file_name: String,
    smb_uri: String,
}

/// Discover subtitle files without registering loopback proxy tokens. Playback
/// and downloads share this exact matching path so they cannot disagree about
/// which sidecars belong to a video.
async fn find_subtitle_files(smb_uri: &str) -> Result<Vec<SmbSubtitleFile>> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let (dir, video_name) = match path.rsplit_once('/') {
        Some((d, n)) => (d.to_string(), n.to_string()),
        None => (String::new(), path.clone()),
    };

    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session_if(&session);
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let entries = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(tree, &dir)).await
    };
    let entries = match entries {
        Ok(Ok(entries)) => {
            session.touch();
            entries
        }
        Ok(Err(error)) => {
            drop(guard);
            invalidate_session_if(&session);
            return Err(error).with_context(|| format!("smb list {dir}"));
        }
        Err(_) => {
            drop(guard);
            invalidate_session_if(&session);
            anyhow::bail!("smb list {dir} timed out")
        }
    };
    drop(guard);

    let mut out = Vec::new();
    for e in entries {
        if e.is_directory || !crate::recognize::subtitle_matches_video(&video_name, &e.name) {
            continue;
        }
        let sub_path = if dir.is_empty() {
            e.name.clone()
        } else {
            format!("{dir}/{}", e.name)
        };
        out.push(SmbSubtitleFile {
            file_name: e.name,
            smb_uri: format!("smb://{}/{}/{}", c.addr, c.share, sub_path),
        });
    }
    Ok(out)
}

/// List external subtitle files sitting next to an SMB video. Return their real
/// SMB URI without allocating proxy tokens; the common subtitle preparation
/// layer reads small files once and normalizes text to UTF-8 before mpv sees it.
pub async fn list_subtitles(smb_uri: &str) -> Result<Vec<crate::models::SubtitleCandidate>> {
    let files = find_subtitle_files(smb_uri).await?;
    Ok(files
        .into_iter()
        .map(|file| crate::models::SubtitleCandidate {
            file_name: file.file_name,
            uri: file.smb_uri,
        })
        .collect())
}

/// Read a small SMB file completely with an explicit size cap. Subtitles and
/// sidecars use this path instead of the range proxy so malformed encodings are
/// decoded once rather than repeatedly during libmpv probes.
pub async fn read_file_limited(smb_uri: &str, limit: usize) -> Result<Vec<u8>> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let c = creds().context("smb not connected")?;
    let (reader, _) = open_session_reader(&c, &path).await?;
    let size = reader.size();
    if size > limit as u64 {
        let _ = reader.close().await;
        anyhow::bail!("remote file exceeds {} bytes", limit);
    }
    let result = async {
        let mut out = Vec::with_capacity(size as usize);
        let mut offset = 0u64;
        while offset < size {
            let want = (size - offset).min(64 * 1024);
            let data = tokio::time::timeout(SETUP_TIMEOUT, reader.read_at(offset, want))
                .await
                .context("smb subtitle read timed out")??;
            if data.is_empty() {
                break;
            }
            offset += data.len() as u64;
            out.extend_from_slice(&data);
        }
        if offset != size {
            anyhow::bail!("incomplete smb read ({offset}/{size} bytes)");
        }
        Ok(out)
    }
    .await;
    let _ = reader.close().await;
    result
}

/// Read the `.kurako-match.json` sidecar in the SMB folder identified by
/// `folder_uri` (an `smb://addr/share/dir` locator). Returns the parsed map, or
/// an empty map if the sidecar is absent/unreadable (a missing sidecar is the
/// normal case for folders the user never corrected).
pub async fn read_sidecar(folder_uri: &str) -> Result<crate::sidecar::SidecarMap> {
    let dir = smb_path_from_uri(folder_uri).context("bad smb folder uri")?;
    let path = if dir.is_empty() {
        crate::sidecar::SIDECAR_NAME.to_string()
    } else {
        format!("{dir}/{}", crate::sidecar::SIDECAR_NAME)
    };
    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session_if(&session);
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let bytes = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.read_file(tree, &path)).await
    };
    drop(guard);
    match bytes {
        Ok(Ok(bytes)) => {
            session.touch();
            Ok(crate::sidecar::parse(&bytes))
        }
        // A confirmed-absent sidecar is the normal case for folders the user
        // never corrected — only THIS may become an empty map.
        Ok(Err(error)) if error.kind() == smb2::ErrorKind::NotFound => {
            session.touch();
            Ok(Default::default())
        }
        // Transport-level failure (dead session, network blip): invalidate so
        // the next attempt reconnects, and surface the error. Treating it as
        // "no sidecar" made a rescan over a dead session silently skip every
        // manual match in the folder — and let the manual-match writer
        // overwrite a populated sidecar with a single entry.
        Ok(Err(error)) => {
            invalidate_session_if(&session);
            Err(error).context("smb read sidecar")
        }
        Err(_) => {
            invalidate_session_if(&session);
            Err(anyhow::anyhow!("smb read sidecar timed out"))
        }
    }
}

/// Write (create or overwrite) the `.kurako-match.json` sidecar in the SMB
/// folder identified by `folder_uri`. Propagates the write error so the caller
/// can warn the user when the share is read-only (no write permission).
pub async fn write_sidecar(folder_uri: &str, map: &crate::sidecar::SidecarMap) -> Result<()> {
    let dir = smb_path_from_uri(folder_uri).context("bad smb folder uri")?;
    let path = if dir.is_empty() {
        crate::sidecar::SIDECAR_NAME.to_string()
    } else {
        format!("{dir}/{}", crate::sidecar::SIDECAR_NAME)
    };
    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let data = crate::sidecar::serialize(map);
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session_if(&session);
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let res = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.write_file(tree, &path, &data)).await
    };
    drop(guard);
    let res = match res {
        Ok(res) => {
            session.touch();
            res
        }
        Err(_) => {
            invalidate_session_if(&session);
            anyhow::bail!("smb write sidecar timed out")
        }
    };
    res.map(|_| ()).context("smb write sidecar")
}

/// Delete the `.kurako-match.json` sidecar in the SMB folder identified by
/// `folder_uri`. Returns whether a file was actually deleted (Ok(false) when the
/// folder had no sidecar). Best-effort — used by the "clear manual matches"
/// maintenance action.
pub async fn delete_sidecar(folder_uri: &str) -> Result<bool> {
    let dir = smb_path_from_uri(folder_uri).context("bad smb folder uri")?;
    let path = if dir.is_empty() {
        crate::sidecar::SIDECAR_NAME.to_string()
    } else {
        format!("{dir}/{}", crate::sidecar::SIDECAR_NAME)
    };
    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session_if(&session);
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let res = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.delete_file(tree, &path)).await
    };
    drop(guard);
    match res {
        Ok(Ok(())) => {
            session.touch();
            Ok(true)
        }
        Ok(Err(error)) if error.kind() == smb2::ErrorKind::NotFound => {
            session.touch();
            Ok(false)
        }
        Ok(Err(error)) => {
            invalidate_session_if(&session);
            Err(error).context("smb delete sidecar")
        }
        Err(_) => {
            invalidate_session_if(&session);
            Err(anyhow::anyhow!("smb delete sidecar timed out"))
        }
    }
}

// ---- Local HTTP streaming proxy ----
//
// libmpv's bundled FFmpeg usually lacks the smb:// protocol, so we serve SMB
// files over a loopback HTTP server that libmpv CAN play. Each registered file
// gets an opaque token; `GET /<token>` streams the bytes and honours `Range`
// requests so seeking works. Bytes are pulled from the share on demand via
// FileReader.read_at — nothing is buffered to disk.

/// token -> smb share-relative path. Registered by `register_playable`.
static PLAYABLE: Lazy<Mutex<HashMap<String, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// Tokens registered for external subtitles. Dart releases only video tokens,
/// so subtitle tokens are grouped by the source video's share-relative path and
/// dropped with the last video token registered for that path.
static SUBTITLE_TOKENS: Lazy<Mutex<HashMap<String, Vec<String>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
/// The port the proxy bound to (0 = not started yet).
static PROXY_PORT: AtomicU16 = AtomicU16::new(0);

/// **Dedicated** runtime for the loopback proxy (accept loop + every `serve`
/// stream task). Kept *separate* from the main `RT` that flutter_rust_bridge
/// drives its `block_on` calls on. This is the core freeze fix: previously the
/// proxy's streaming tasks were spawned on the shared RT, so a burst of rapid
/// episode switches (even within one folder) piled up serve tasks that occupied
/// all worker threads, and the next episode's `block_on` (resolve/register)
/// could no longer get a thread — wedging the whole UI. Isolating proxy I/O here
/// means no amount of SMB streaming can starve the calls the UI waits on.
static PROXY_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("smb-proxy")
        .enable_all()
        .build()
        .expect("smb proxy runtime")
});

/// Cap concurrent reads against the shared session. A player can issue several
/// speculative range probes for one file; two are enough for smooth playback
/// while keeping a small SMB server's open-handle queue under control.
static SMB_CONN: Lazy<tokio::sync::Semaphore> = Lazy::new(|| tokio::sync::Semaphore::new(2));

/// Downloads get their own single-permit pool. A whole-file transfer holds its
/// permit for minutes; sharing [SMB_CONN] with playback meant one active
/// download halved the playback read pool (every seek queued behind it) and
/// two downloads starved playback entirely. The persistent session multiplexes
/// requests, so one extra long-lived read stream is fine for the NAS.
static SMB_DL_CONN: Lazy<tokio::sync::Semaphore> = Lazy::new(|| tokio::sync::Semaphore::new(1));

/// Get the persistent session, connecting on first use.
async fn session(c: &SmbCreds) -> Result<std::sync::Arc<SmbSession>> {
    // Clone out of the mutex in its own statement: an `if let` on the guard
    // keeps the temporary MutexGuard alive for the whole block (edition 2021),
    // and the re-lock below would self-deadlock inside frb's block_on.
    let cached_session = SESSION.lock().unwrap().clone();
    if let Some(s) = cached_session {
        // Only rotate an idle connection if nothing is currently flowing
        // through the loopback proxy.  This keeps one stable SMB session for
        // normal playback, but avoids paying a 12-second stale-socket timeout
        // after the app has sat unused or backgrounded for a while.
        if !s.has_been_idle_too_long() || !ACTIVE_STREAMS.lock().unwrap().is_empty() {
            return Ok(s);
        }
        invalidate_session_if(&s);
    }
    let _guard = SESSION_INIT.lock().await;
    // Re-check: another caller may have connected while we waited for the lock.
    if let Some(s) = SESSION.lock().unwrap().clone() {
        return Ok(s);
    }
    let (client, tree) = open(c).await?;
    let s = std::sync::Arc::new(SmbSession::new(client, tree));
    *SESSION.lock().unwrap() = Some(s.clone());
    Ok(s)
}

/// Open a remote file through the reusable session.  NASes commonly close an
/// otherwise-idle SMB session without notifying the client; retrying once with
/// a newly authenticated session makes that recoverable instead of surfacing
/// a spurious HTTP 500 to the iOS loopback player.
/// Returns the reader together with the session it was opened on, so a later
/// read failure can invalidate exactly that session (see
/// [invalidate_session_if]) instead of whatever happens to be cached by then.
async fn open_session_reader(
    c: &SmbCreds,
    path: &str,
) -> Result<(smb2::FileReader, std::sync::Arc<SmbSession>)> {
    let mut last_error = None;
    for attempt in 0..2 {
        let sess = match session(c).await {
            Ok(s) => s,
            Err(e) => {
                // session() failed to CREATE a session, so there is nothing of
                // ours to invalidate — and a concurrent caller may have cached
                // a fresh healthy one in the meantime, which a blanket clear
                // here would needlessly kill.
                last_error = Some(e);
                continue;
            }
        };
        let guard = match tokio::time::timeout(SETUP_TIMEOUT, sess.inner.lock()).await {
            Ok(guard) => guard,
            Err(_) => {
                last_error = Some(anyhow::anyhow!("smb session remained busy for too long"));
                invalidate_session_if(&sess);
                continue;
            }
        };
        let SmbSessionInner { client, tree } = &*guard;
        let open_result =
            tokio::time::timeout(SETUP_TIMEOUT, client.open_file_reader(tree, path)).await;
        drop(guard);
        match open_result {
            Ok(Ok(reader)) => {
                sess.touch();
                return Ok((reader, sess));
            }
            Ok(Err(e)) => last_error = Some(e.into()),
            Err(_) => last_error = Some(anyhow::anyhow!("smb open file timed out")),
        }
        invalidate_session_if(&sess);
        if attempt == 0 {
            continue;
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("smb open file failed")))
}

/// Unconditionally drop the cached session. Reserved for explicit
/// reconfiguration (credentials changed / user-initiated reconnect), where any
/// cached session must not survive regardless of which task created it.
/// Failure paths must use [invalidate_session_if] instead.
fn invalidate_session() {
    *SESSION.lock().unwrap() = None;
}

/// Drop the cached session only if it is still `failed` — the session whose
/// operation actually errored (presumed dead: NAS idle-closed it, network
/// blip). An unconditional clear here would let an old stream failing late
/// tear down the healthy replacement another task just paid a handshake for,
/// triggering a reconnect storm. In-flight `FileReader`s are unaffected (each
/// owns its own cloned connection handle once opened).
fn invalidate_session_if(failed: &std::sync::Arc<SmbSession>) {
    let mut cached = SESSION.lock().unwrap();
    if cached
        .as_ref()
        .is_some_and(|current| std::sync::Arc::ptr_eq(current, failed))
    {
        *cached = None;
    }
}

/// Serializes proxy start-up so two concurrent `register_playable` calls don't
/// both bind a listener.
static PROXY_INIT: Mutex<()> = Mutex::new(());
static TOKEN_SEQ: AtomicU64 = AtomicU64::new(1);
/// One in-flight loopback request. Keeping its token is essential: a late
/// release from a superseded Dart open must cancel only that old URL, never the
/// new episode which may already be reading through the same proxy.
struct ActiveStream {
    token: String,
    cancellation: tokio::sync::watch::Sender<bool>,
    started_at: Instant,
}

/// Active proxy streams keyed by request id. Do not abort tasks directly:
/// `FileReader` needs async `close()` to release its remote SMB handle.
static ACTIVE_STREAMS: Lazy<Mutex<HashMap<u64, ActiveStream>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static STREAM_SEQ: AtomicU64 = AtomicU64::new(1);

/// A loopback listener can disappear after an iOS background/foreground cycle
/// or a runtime-level socket error.  `PROXY_PORT` is only a cached number, so
/// verify that it still accepts connections before handing it to libmpv.
fn proxy_is_alive(port: u16) -> bool {
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    std::net::TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(250)).is_ok()
}

/// Clear the cached port only if it still refers to this exact listener.  An
/// older accept task must never erase a newer listener that was started after
/// it failed.
fn clear_proxy_port(port: u16) {
    let _ = PROXY_PORT.compare_exchange(port, 0, Ordering::AcqRel, Ordering::Acquire);
}

/// Ask only streams belonging to [tokens] to finish their async SMB close.
/// Global cancellation made rapid switches nondeterministic: releasing an old
/// handle after the next URL started would truncate the new HTTP body too.
fn cancel_streams_for_tokens(tokens: &HashSet<String>) {
    let cancellations: Vec<tokio::sync::watch::Sender<bool>> = {
        let mut streams = ACTIVE_STREAMS.lock().unwrap();
        let ids: Vec<u64> = streams
            .iter()
            .filter_map(|(id, stream)| tokens.contains(&stream.token).then_some(*id))
            .collect();
        ids.into_iter()
            .filter_map(|id| streams.remove(&id).map(|stream| stream.cancellation))
            .collect()
    };
    for cancellation in cancellations {
        let _ = cancellation.send(true);
    }
}

fn playback_download_yield() -> Option<Duration> {
    const STARTUP_PRIORITY_WINDOW: Duration = Duration::from_secs(3);
    const STARTUP_YIELD: Duration = Duration::from_millis(60);
    const STEADY_YIELD: Duration = Duration::from_millis(15);

    let streams = ACTIVE_STREAMS.lock().unwrap();
    if streams.is_empty() {
        return None;
    }
    if streams
        .values()
        .any(|stream| stream.started_at.elapsed() < STARTUP_PRIORITY_WINDOW)
    {
        Some(STARTUP_YIELD)
    } else {
        Some(STEADY_YIELD)
    }
}
/// Total bytes streamed to clients since process start. Dart polls this and
/// derives MB/s from consecutive samples (for the playback-info panel).
static BYTES_SERVED: AtomicU64 = AtomicU64::new(0);

/// Cumulative bytes served by the proxy (monotonic counter).
pub fn proxy_bytes_served() -> u64 {
    BYTES_SERVED.load(Ordering::Relaxed)
}

/// Register an SMB URI for playback and return `http://127.0.0.1:port/<token>`.
/// Starts the proxy on first use. Must be called from within the tokio runtime.
pub async fn register_playable(smb_uri: &str) -> Result<String> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let port = ensure_proxy()?;
    let token = format!("t{}", TOKEN_SEQ.fetch_add(1, Ordering::Relaxed));
    PLAYABLE.lock().unwrap().insert(token.clone(), path);
    Ok(format!("http://127.0.0.1:{port}/{token}"))
}

/// Drop a previously registered token (called when playback ends).
pub fn unregister_playable(url: &str) {
    let mut released_tokens = HashSet::new();
    let video_path = url.rsplit('/').next().and_then(|token| {
        released_tokens.insert(token.to_string());
        PLAYABLE.lock().unwrap().remove(token)
    });
    // Keep the sidecars while another attempt for the same video is registered.
    // This covers a late release from a superseded retry of the same episode.
    if let Some(video_path) = video_path {
        let same_video_still_registered = PLAYABLE
            .lock()
            .unwrap()
            .values()
            .any(|path| path == &video_path);
        if !same_video_still_registered {
            if let Some(subs) = SUBTITLE_TOKENS.lock().unwrap().remove(&video_path) {
                released_tokens.extend(subs);
            }
        }
    }
    // A stale Dart subtitle-list operation may release a sidecar URL directly
    // after its owning video token has already gone. Remove that token from any
    // pending ownership list as well, so the bookkeeping cannot leak forever.
    {
        let mut subtitle_tokens = SUBTITLE_TOKENS.lock().unwrap();
        for tokens in subtitle_tokens.values_mut() {
            tokens.retain(|token| !released_tokens.contains(token));
        }
        subtitle_tokens.retain(|_, tokens| !tokens.is_empty());
    }
    if !released_tokens.is_empty() {
        let mut playable = PLAYABLE.lock().unwrap();
        for token in &released_tokens {
            playable.remove(token);
        }
    }
    cancel_streams_for_tokens(&released_tokens);
}

/// Start the loopback HTTP server once (on the dedicated `PROXY_RT`); returns
/// its port. Synchronous: binds with std then hands the listener to `PROXY_RT`,
/// so it never runs the accept/serve loop on the shared `RT`.
fn ensure_proxy() -> Result<u16> {
    let existing = PROXY_PORT.load(Ordering::Acquire);
    if existing != 0 && proxy_is_alive(existing) {
        return Ok(existing);
    }
    if existing != 0 {
        clear_proxy_port(existing);
    }
    let _guard = PROXY_INIT.lock().unwrap();
    // Re-check under the lock: another caller may have started it while we waited.
    let existing = PROXY_PORT.load(Ordering::Acquire);
    if existing != 0 && proxy_is_alive(existing) {
        return Ok(existing);
    }
    if existing != 0 {
        clear_proxy_port(existing);
    }
    let std_listener = std::net::TcpListener::bind("127.0.0.1:0").context("bind proxy")?;
    std_listener
        .set_nonblocking(true)
        .context("proxy listener nonblocking")?;
    let port = std_listener.local_addr()?.port();
    // Publish before spawning, so an immediately-failing task can reliably
    // clear its own port.  The already-bound socket accepts a health probe even
    // while Tokio is scheduling the accept loop.
    PROXY_PORT.store(port, Ordering::Release);
    PROXY_RT.spawn(async move {
        let listener = match TcpListener::from_std(std_listener) {
            Ok(l) => l,
            Err(_) => {
                clear_proxy_port(port);
                return;
            }
        };
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let id = STREAM_SEQ.fetch_add(1, Ordering::Relaxed);
                    // serve() runs on PROXY_RT (current runtime), isolated from RT.
                    let jh = tokio::spawn(async move {
                        let _ = serve(stream, id).await;
                        ACTIVE_STREAMS.lock().unwrap().remove(&id);
                    });
                    // Keep the task detached: it must be allowed to close the
                    // remote reader after receiving a cancellation signal.
                    drop(jh);
                }
                Err(_) => {
                    clear_proxy_port(port);
                    break;
                }
            }
        }
    });
    Ok(port)
}

/// Handle one HTTP request: parse the token + optional Range, stream the file.
async fn serve(mut stream: TcpStream, stream_id: u64) -> Result<()> {
    // Read headers (until CRLFCRLF). Video requests are tiny, 8KB is plenty.
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = match tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut tmp))
            .await
        {
            Ok(result) => result?,
            Err(_) => return Ok(()),
        };
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") || buf.len() > 16384 {
            break;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    // "GET /<token> HTTP/1.1". mpv on iOS probes HTTP sources with HEAD
    // before opening a GET stream; treating that as a normal GET sends an
    // unexpected media body and can leave its URL loader stuck in loading.
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or("GET");
    let token = request_parts
        .next()
        .unwrap_or("/")
        .trim_start_matches('/')
        .to_string();
    let mut range: Option<ByteRange> = None;
    for line in lines {
        if let Some(v) = line
            .strip_prefix("Range:")
            .or_else(|| line.strip_prefix("range:"))
        {
            range = parse_range(v.trim());
        }
    }

    let path = PLAYABLE.lock().unwrap().get(&token).cloned();
    let Some(path) = path else {
        let _ = stream
            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            .await;
        return Ok(());
    };

    // Register only after the token has been parsed, so releases can target the
    // correct request. Recheck PLAYABLE after insertion to close the tiny race
    // where the token is released between the first lookup and this insert.
    let (cancel_tx, mut cancelled) = tokio::sync::watch::channel(false);
    ACTIVE_STREAMS.lock().unwrap().insert(
        stream_id,
        ActiveStream {
            token: token.clone(),
            cancellation: cancel_tx,
            started_at: Instant::now(),
        },
    );
    if !PLAYABLE.lock().unwrap().contains_key(&token) {
        ACTIVE_STREAMS.lock().unwrap().remove(&stream_id);
        return Ok(());
    }

    let Some(c) = creds() else {
        write_http_error(&mut stream, "500 No SMB", "SMB credentials are unavailable").await;
        return Ok(());
    };

    // Bound concurrent reads against the shared session (see [SMB_CONN]). A
    // cancelled stale request must not wait in this queue and later open a
    // remote file after the user has already changed episodes.
    let _permit = tokio::select! {
        _ = cancelled.changed() => return Ok(()),
        permit = SMB_CONN.acquire() => permit.expect("SMB semaphore closed"),
    };

    // Reuse the persistent session (see [SESSION]) instead of connecting fresh
    // per request — this is the fix for the cumulative-switches freeze. Every
    // step stays bounded (see SETUP_TIMEOUT): on a timeout / error we invalidate
    // the session (it's presumed dead) and answer with a real HTTP 500, so
    // libmpv sees a clean failure — and the *next* request reconnects — instead
    // of spinning forever or repeatedly failing against a stale handle.
    let (reader, sess) = match open_session_reader(&c, &path).await {
        Ok(r) => r,
        Err(e) => {
            write_http_error(&mut stream, "500 SMB Open Failed", &format!("{e:#}")).await;
            return Ok(());
        }
    };
    let total = reader.size();

    if total == 0 {
        let _ = reader.close().await;
        write_http_error(
            &mut stream,
            "404 Empty File",
            "SMB reported a zero-byte video file",
        )
        .await;
        return Ok(());
    }

    // Resolve the range against the file size (total > 0 checked above).
    // An inverted range (`bytes=500-100`) is syntactically invalid per RFC
    // 7233, and MUST be ignored, so the whole file is served as 200 — the old
    // clamping produced 206 + Content-Length:1 with an empty body, hanging the
    // client on a byte that never came. A suffix range asks for the last n
    // bytes; n == 0 resolves to start == total and falls into the 416 below.
    if let Some(ByteRange::FromTo(s, Some(e))) = range {
        if e < s {
            range = None;
        }
    }
    let (start, end) = match range {
        Some(ByteRange::FromTo(s, e)) => (s, e.unwrap_or(u64::MAX).min(total - 1)),
        Some(ByteRange::Suffix(n)) => (total.saturating_sub(n), total - 1),
        None => (0, total - 1),
    };
    if start >= total {
        let _ = reader.close().await;
        let response = format!(
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let _ = stream.write_all(response.as_bytes()).await;
        return Ok(());
    }
    let len = end.saturating_sub(start) + 1;

    // Response headers.
    let status = if range.is_some() {
        "HTTP/1.1 206 Partial Content"
    } else {
        "HTTP/1.1 200 OK"
    };
    let content_type = mime_for_path(&path);
    let mut header = format!(
        "{status}\r\nContent-Type: {content_type}\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\nConnection: close\r\n"
    );
    if range.is_some() {
        header.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    }
    header.push_str("\r\n");
    if tokio::select! {
        _ = cancelled.changed() => true,
        result = stream.write_all(header.as_bytes()) => result.is_err(),
    } {
        let _ = reader.close().await;
        return Ok(());
    }
    if method.eq_ignore_ascii_case("HEAD") {
        let _ = reader.close().await;
        return Ok(());
    }

    // Stream in chunks from the share.
    const CHUNK: u64 = 256 * 1024;
    let mut off = start;
    while off <= end {
        // Stop as soon as this stream's token is released (episode/anime switch
        // unregisters it): keeps a superseded stream from streaming into a dead
        // socket and holding a worker thread + NAS connection during rapid
        // switching (the freeze). The live player disconnects the socket too,
        // but the token check reacts immediately without waiting on that.
        if !PLAYABLE.lock().unwrap().contains_key(&token) {
            break;
        }
        let want = CHUNK.min(end - off + 1);
        // Bound each read so a hung NAS can't pin a worker thread forever.
        let data = match tokio::select! {
            _ = cancelled.changed() => {
                let _ = reader.close().await;
                return Ok(());
            }
            result = tokio::time::timeout(
                std::time::Duration::from_secs(30),
                reader.read_at(off, want),
            ) => result,
        } {
            Ok(Ok(d)) => d,
            _ => {
                // Read failed/timed out on the shared session — assume the
                // connection died (NAS idle-closed it, network blip) so the
                // next request reconnects instead of repeating the same error.
                // Only invalidate OUR session: a newer one may already exist.
                invalidate_session_if(&sess);
                break;
            }
        };
        if data.is_empty() {
            break;
        }
        if stream.write_all(&data).await.is_err() {
            break; // client disconnected (seek / closed)
        }
        BYTES_SERVED.fetch_add(data.len() as u64, Ordering::Relaxed);
        off += data.len() as u64;
    }
    // FileReader owns a remote SMB handle. Dropping it without `close` leaks
    // that handle on the server until the whole session is torn down; a few
    // iOS HEAD/range probes were therefore enough to exhaust some SMB servers.
    let _ = reader.close().await;
    // No session disconnect here: it is reused by future streams. Only an
    // actual read/open failure invalidates it.
    Ok(())
}

/// Send a small human-readable error body so Dart can report why iOS received
/// HTTP 500 instead of reducing every SMB failure to an opaque status code.
async fn write_http_error(stream: &mut TcpStream, status: &str, detail: &str) {
    let body = detail.replace(['\r', '\n'], " ");
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
}

/// A conservative content type lets iOS' URL loader identify MP4/MOV streams
/// before handing them to libmpv. Unknown formats remain generic video.
pub(crate) fn mime_for_path(path: &str) -> &'static str {
    match path
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
    {
        Some(ext) if ext == "mkv" => "video/x-matroska",
        Some(ext) if ext == "mp4" || ext == "m4v" => "video/mp4",
        Some(ext) if ext == "mov" => "video/quicktime",
        Some(ext) if ext == "webm" => "video/webm",
        Some(ext) if ext == "avi" => "video/x-msvideo",
        Some(ext) if ext == "ts" || ext == "m2ts" => "video/mp2t",
        Some(ext) if ext == "srt" => "application/x-subrip; charset=utf-8",
        Some(ext) if ext == "ass" || ext == "ssa" => "text/x-ssa; charset=utf-8",
        Some(ext) if ext == "vtt" => "text/vtt; charset=utf-8",
        Some(ext) if ext == "smi" || ext == "sami" => "application/x-sami; charset=utf-8",
        Some(ext) if ext == "lrc" || ext == "mpl" || ext == "mpl2" => "text/plain; charset=utf-8",
        _ => "video/*",
    }
}

/// A parsed `Range` header value.
#[derive(Clone, Copy)]
enum ByteRange {
    /// `bytes=start-` / `bytes=start-end`.
    FromTo(u64, Option<u64>),
    /// `bytes=-n`: the last n bytes of the file.
    Suffix(u64),
}

/// Parse a `bytes=...` Range header value, including the suffix form `bytes=-n`
/// (mpv uses it to probe an mp4's trailing moov atom — failing to parse it
/// silently degraded to a 200 full-file response, pulling the whole file
/// through the share before playback could start).
fn parse_range(v: &str) -> Option<ByteRange> {
    let v = v.strip_prefix("bytes=")?;
    let (s, e) = v.split_once('-')?;
    let s = s.trim();
    let e = e.trim();
    if s.is_empty() {
        return Some(ByteRange::Suffix(e.parse().ok()?));
    }
    let start: u64 = s.parse().ok()?;
    let end = if e.is_empty() {
        None
    } else {
        Some(e.parse().ok()?)
    };
    Some(ByteRange::FromTo(start, end))
}

// ---- Download to local ----

/// URIs whose in-flight download the user cancelled; checked between chunks.
/// Per-URI so concurrent downloads cancel independently.
static DOWNLOAD_CANCELLED: Lazy<Mutex<std::collections::HashSet<String>>> =
    Lazy::new(|| Mutex::new(std::collections::HashSet::new()));

pub fn cancel_download(smb_uri: &str) {
    DOWNLOAD_CANCELLED
        .lock()
        .unwrap()
        .insert(smb_uri.to_string());
}

pub fn reset_download_cancellation(smb_uri: &str) {
    DOWNLOAD_CANCELLED.lock().unwrap().remove(smb_uri);
}

fn is_cancelled(smb_uri: &str) -> bool {
    DOWNLOAD_CANCELLED.lock().unwrap().contains(smb_uri)
}

pub fn download_was_cancelled(smb_uri: &str) -> bool {
    is_cancelled(smb_uri)
}

async fn acquire_download_permit(smb_uri: &str) -> Result<tokio::sync::SemaphorePermit<'static>> {
    loop {
        match tokio::time::timeout(std::time::Duration::from_millis(300), SMB_DL_CONN.acquire())
            .await
        {
            Ok(permit) => return Ok(permit.expect("smb download semaphore closed")),
            Err(_) if is_cancelled(smb_uri) => anyhow::bail!("下载已取消"),
            Err(_) => {}
        }
    }
}

/// Download an SMB file into `dest_dir`, reporting progress via `progress`.
/// Writes to `<name>.part` and renames on completion so an interrupted download
/// never masquerades as a finished file. Returns the final local path.
pub async fn download(
    smb_uri: &str,
    dest_dir: &str,
    progress: impl Fn(u64, u64),
) -> Result<String> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let file_name = path.rsplit('/').next().unwrap_or(&path).to_string();
    let c = creds().context("smb not connected")?;
    // Downloads used to establish a second TCP/authenticated SMB session even
    // while the proxy was playing. Many NASes limit sessions or open handles
    // per client; reuse the same multiplexed session as the proxy instead.
    tokio::fs::create_dir_all(dest_dir)
        .await
        .context("create download dir")?;
    let final_path = std::path::Path::new(dest_dir).join(&file_name);
    let part_path = final_path.with_extension(format!(
        "{}.part",
        final_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("bin")
    ));

    // Queue among downloads only (playback has its own pool — [SMB_CONN]),
    // and poll the cancel flag while waiting so a still-queued download reacts
    // to 取消 immediately instead of only once it finally gets the permit.
    let _permit = acquire_download_permit(smb_uri).await?;
    if is_cancelled(smb_uri) {
        anyhow::bail!("下载已取消");
    }
    let (reader, sess) = open_session_reader(&c, &path).await?;
    let total = reader.size();

    // A zero-length video is never a valid completed download. Previously the
    // loop below was skipped and a zero-byte file was recorded as successful,
    // which is exactly the "instant completion but no file" symptom on iOS.
    if total == 0 {
        let _ = reader.close().await;
        anyhow::bail!("SMB reported this video as 0 bytes; download was not saved");
    }

    let mut out = match tokio::fs::File::create(&part_path).await {
        Ok(file) => file,
        Err(error) => {
            let _ = reader.close().await;
            return Err(error).context("create .part file");
        }
    };

    // Smaller requests keep the shared SMB2 connection responsive to libmpv.
    // While a proxy stream is active, each background chunk yields briefly so
    // a whole-file transfer cannot monopolize server credits or Wi-Fi airtime.
    const CHUNK: u64 = 256 * 1024;
    let mut off: u64 = 0;
    let transfer_result: Result<()> = async {
        while off < total {
            if is_cancelled(smb_uri) {
                anyhow::bail!("下载已取消");
            }
            if let Some(delay) = playback_download_yield() {
                tokio::time::sleep(delay).await;
            }
            let want = CHUNK.min(total - off);
            let data = match tokio::time::timeout(
                std::time::Duration::from_secs(30),
                reader.read_at(off, want),
            )
            .await
            {
                Ok(Ok(data)) => data,
                Ok(Err(error)) => {
                    invalidate_session_if(&sess);
                    return Err(error).context("smb read");
                }
                Err(_) => {
                    invalidate_session_if(&sess);
                    anyhow::bail!("smb download read timed out")
                }
            };
            if data.is_empty() {
                break;
            }
            out.write_all(&data).await.context("write local file")?;
            off += data.len() as u64;
            progress(off, total);
        }
        out.flush().await.context("flush local file")?;
        Ok(())
    }
    .await;
    drop(out);
    let _ = reader.close().await;

    if let Err(e) = transfer_result {
        let _ = tokio::fs::remove_file(&part_path).await;
        return Err(e);
    }

    if off < total {
        let _ = tokio::fs::remove_file(&part_path).await;
        anyhow::bail!("下载不完整（{}/{} 字节）", off, total);
    }
    tokio::fs::rename(&part_path, &final_path)
        .await
        .context("rename .part")?;
    Ok(final_path.to_string_lossy().to_string())
}

pub fn expected_download_path(smb_uri: &str, dest_dir: &str) -> Option<std::path::PathBuf> {
    let path = smb_path_from_uri(smb_uri)?;
    let file_name = path.rsplit('/').next().unwrap_or(&path);
    Some(std::path::Path::new(dest_dir).join(file_name))
}

/// Reuse an orphaned local video only after its byte size matches the exact SMB
/// source. This avoids binding a same-named file from another folder without
/// transferring the entire video again.
pub async fn matching_existing_download(
    smb_uri: &str,
    dest_dir: &str,
) -> Result<Option<(String, u64)>> {
    let Some(local_path) = expected_download_path(smb_uri, dest_dir) else {
        return Ok(None);
    };
    let local_size = match tokio::fs::metadata(&local_path).await {
        Ok(metadata) if metadata.is_file() && metadata.len() > 0 => metadata.len(),
        _ => return Ok(None),
    };
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let c = creds().context("smb not connected")?;
    let (reader, _) = open_session_reader(&c, &path).await?;
    let remote_size = reader.size();
    let _ = reader.close().await;
    if remote_size == local_size {
        Ok(Some((local_path.to_string_lossy().to_string(), local_size)))
    } else {
        Ok(None)
    }
}

/// Download every matching SMB sidecar into one dedicated folder below the
/// video download directory. Subtitle failures are reported to the caller but
/// do not remove the already-completed video; cancellation remains tied to the
/// original video's task.
pub async fn download_subtitles(smb_uri: &str, dest_dir: &str) -> Result<Vec<String>> {
    let files = find_subtitle_files(smb_uri).await?;
    let video_name = smb_path_from_uri(smb_uri)
        .and_then(|path| path.rsplit('/').next().map(str::to_string))
        .context("bad smb uri")?;
    let local_video = std::path::Path::new(dest_dir).join(&video_name);
    remove_downloaded_subtitles(&local_video);
    if files.is_empty() {
        return Ok(Vec::new());
    }

    let subtitle_dir = std::path::Path::new(dest_dir).join(DOWNLOADED_SUBTITLE_DIR);
    let subtitle_dir = subtitle_dir.to_string_lossy().to_string();
    let mut downloaded = Vec::with_capacity(files.len());
    for file in files {
        if is_cancelled(smb_uri) {
            anyhow::bail!("下载已取消");
        }
        reset_download_cancellation(&file.smb_uri);
        match download(&file.smb_uri, &subtitle_dir, |_, _| {}).await {
            Ok(path) => downloaded.push(path),
            Err(error) => eprintln!(
                "KURAKO could not download subtitle {}: {error:#}",
                file.file_name
            ),
        }
    }
    if is_cancelled(smb_uri) {
        anyhow::bail!("下载已取消");
    }
    Ok(downloaded)
}

/// Remove sidecars downloaded for [video_path]. Only the dedicated subtitle
/// directory is touched; user-managed files next to the video are never
/// removed.
pub fn remove_downloaded_subtitles(video_path: impl AsRef<std::path::Path>) {
    let video_path = video_path.as_ref();
    let Some(video_name) = video_path.file_name().and_then(|name| name.to_str()) else {
        return;
    };
    let Some(parent) = video_path.parent() else {
        return;
    };
    let subtitle_dir = parent.join(DOWNLOADED_SUBTITLE_DIR);
    let Ok(entries) = std::fs::read_dir(&subtitle_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if path.is_file() && crate::recognize::subtitle_matches_video(video_name, name) {
            let _ = std::fs::remove_file(path);
        }
    }
    if std::fs::read_dir(&subtitle_dir)
        .map(|mut entries| entries.next().is_none())
        .unwrap_or(false)
    {
        let _ = std::fs::remove_dir(subtitle_dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn queued_download_slot_can_be_cancelled() {
        let held = SMB_DL_CONN.acquire().await.unwrap();
        let uri = "smb://test/queued-download".to_string();
        DOWNLOAD_CANCELLED.lock().unwrap().remove(&uri);

        let cancel_uri = uri.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            cancel_download(&cancel_uri);
        });

        let result = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            acquire_download_permit(&uri),
        )
        .await
        .expect("queued download ignored cancellation");
        assert!(result.is_err());

        DOWNLOAD_CANCELLED.lock().unwrap().remove(&uri);
        drop(held);
    }

    #[test]
    fn subtitle_matching_uses_shared_recognizer() {
        assert!(crate::recognize::subtitle_matches_video(
            "Episode 01.mkv",
            "Episode 01.sc.ass"
        ));
        assert!(crate::recognize::subtitle_matches_video(
            "Episode 01.mkv",
            "Episode 01.srt"
        ));
        assert!(!crate::recognize::subtitle_matches_video(
            "Episode 01.mkv",
            "Episode 02.sc.ass"
        ));
        assert!(!crate::recognize::subtitle_matches_video(
            "Episode 01.mkv",
            "Episode 01.txt"
        ));
    }

    #[test]
    fn downloaded_subtitle_cleanup_keeps_unrelated_files() {
        let root = std::env::temp_dir().join(format!(
            "kurako-subtitle-cleanup-{}-{}",
            std::process::id(),
            STREAM_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let subtitle_dir = root.join(DOWNLOADED_SUBTITLE_DIR);
        std::fs::create_dir_all(&subtitle_dir).unwrap();
        let video = root.join("Episode 01.mkv");
        std::fs::write(&video, b"video").unwrap();
        std::fs::write(subtitle_dir.join("Episode 01.sc.ass"), b"sub").unwrap();
        std::fs::write(subtitle_dir.join("Episode 01.tc.srt"), b"sub").unwrap();
        let unrelated = subtitle_dir.join("Episode 02.sc.ass");
        std::fs::write(&unrelated, b"keep").unwrap();

        remove_downloaded_subtitles(&video);

        assert!(!subtitle_dir.join("Episode 01.sc.ass").exists());
        assert!(!subtitle_dir.join("Episode 01.tc.srt").exists());
        assert!(unrelated.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unregistering_one_token_does_not_cancel_another_stream() {
        let first_id = STREAM_SEQ.fetch_add(1, Ordering::Relaxed);
        let second_id = STREAM_SEQ.fetch_add(1, Ordering::Relaxed);
        let first_token = format!("test-old-{first_id}");
        let second_token = format!("test-new-{second_id}");
        let (first_tx, first_rx) = tokio::sync::watch::channel(false);
        let (second_tx, second_rx) = tokio::sync::watch::channel(false);
        {
            let mut playable = PLAYABLE.lock().unwrap();
            playable.insert(first_token.clone(), "old/video.mkv".to_string());
            playable.insert(second_token.clone(), "new/video.mkv".to_string());
        }
        {
            let mut streams = ACTIVE_STREAMS.lock().unwrap();
            streams.insert(
                first_id,
                ActiveStream {
                    token: first_token.clone(),
                    cancellation: first_tx,
                    started_at: Instant::now(),
                },
            );
            streams.insert(
                second_id,
                ActiveStream {
                    token: second_token.clone(),
                    cancellation: second_tx,
                    started_at: Instant::now(),
                },
            );
        }

        unregister_playable(&format!("http://127.0.0.1:1/{first_token}"));

        assert_eq!(*first_rx.borrow(), true);
        assert_eq!(*second_rx.borrow(), false);
        let mut streams = ACTIVE_STREAMS.lock().unwrap();
        assert!(!streams.contains_key(&first_id));
        assert!(streams.remove(&second_id).is_some());
        PLAYABLE.lock().unwrap().remove(&second_token);
    }
}
