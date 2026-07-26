//! SMB2/3 network-share client, built on the pure-Rust `smb2` crate.
//!
//! A share is added as a library folder with `source_type = "smb"` and a path
//! like `smb://host[:port]/share/subdir`. Credentials are cached process-wide
//! after a successful connect. Enumeration lists the tree into `ScannedFile`s
//! (reusing the same recognition/grouping as local + SAF). Playback is served
//! through a local HTTP proxy (see the `proxy` section) because libmpv's bundled
//! FFmpeg usually lacks the `smb://` protocol.

use crate::models::{ScannedFile, SmbDirectory, SmbServer, SmbShare};
use anyhow::{Context, Result};
use futures::stream::{self, StreamExt};
use once_cell::sync::Lazy;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU16, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "m2ts", "rmvb", "rm", "mpg",
    "mpeg", "3gp", "ogv",
];

const SUBTITLE_EXTS: &[&str] = &["ass", "srt", "ssa", "sub", "vtt"];

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

/// Discovery is deliberately restricted to one private /24. This covers the
/// overwhelmingly common home Wi-Fi/LAN layout without probing a routed VPN or
/// a whole corporate subnet. NetBIOS broadcast responses are merged with the
/// TCP/445 probe, so older Windows hosts and common NAS appliances both appear.
const DISCOVERY_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(450);

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

fn is_video(name: &str) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => VIDEO_EXTS.contains(&ext.to_ascii_lowercase().as_str()),
        None => false,
    }
}

fn is_subtitle(name: &str) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => SUBTITLE_EXTS.contains(&ext.to_ascii_lowercase().as_str()),
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

fn private_ipv4(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    octets[0] == 10
        || (octets[0] == 172 && (16..=31).contains(&octets[1]))
        || (octets[0] == 192 && octets[1] == 168)
}

/// Ask the OS which local interface it would use for a normal Internet route.
/// UDP `connect` does not send a packet; it only lets us read the chosen local
/// address and avoids platform-specific Kotlin/Swift interface enumeration.
async fn default_local_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind("0.0.0.0:0").await.ok()?;
    socket.connect("1.1.1.1:53").await.ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if private_ipv4(ip) => Some(ip),
        _ => None,
    }
}

fn netbios_wildcard_query() -> Vec<u8> {
    // RFC 1002 first-level encoding for the wildcard NetBIOS name "*" padded
    // to 15 characters, followed by the workstation suffix 0x00.
    let mut name = [b' '; 16];
    name[0] = b'*';
    name[15] = 0;
    let mut packet = Vec::with_capacity(50);
    packet.extend_from_slice(&0x4B55u16.to_be_bytes());
    packet.extend_from_slice(&0x0010u16.to_be_bytes()); // broadcast query
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&0u16.to_be_bytes());
    packet.extend_from_slice(&0u16.to_be_bytes());
    packet.extend_from_slice(&0u16.to_be_bytes());
    packet.push(32);
    for byte in name {
        packet.push(b'A' + ((byte >> 4) & 0x0F));
        packet.push(b'A' + (byte & 0x0F));
    }
    packet.push(0);
    packet.extend_from_slice(&0x0020u16.to_be_bytes()); // NB
    packet.extend_from_slice(&0x0001u16.to_be_bytes()); // IN
    packet
}

async fn netbios_broadcast_hosts(local: Ipv4Addr) -> Vec<Ipv4Addr> {
    let Ok(socket) = UdpSocket::bind("0.0.0.0:0").await else {
        return Vec::new();
    };
    if socket.set_broadcast(true).is_err() {
        return Vec::new();
    }
    let mut octets = local.octets();
    octets[3] = 255;
    let _ = socket
        .send_to(
            &netbios_wildcard_query(),
            SocketAddr::from((Ipv4Addr::from(octets), 137)),
        )
        .await;

    let mut found = HashSet::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(900);
    let mut buf = [0u8; 1024];
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await {
            Ok(Ok((_, SocketAddr::V4(addr)))) if private_ipv4(*addr.ip()) => {
                found.insert(*addr.ip());
            }
            _ => break,
        }
    }
    found.into_iter().collect()
}

/// Locate reachable SMB servers on the current LAN. A NetBIOS broadcast gives
/// older Windows/NAS devices a chance to announce themselves; a bounded TCP
/// probe of the local /24 also finds modern SMB2/3-only servers that suppress
/// broadcast replies (including many NAS distributions).
pub async fn discover_servers() -> Vec<SmbServer> {
    let Some(local) = default_local_ipv4().await else {
        return Vec::new();
    };
    let mut targets: HashSet<Ipv4Addr> = netbios_broadcast_hosts(local).await.into_iter().collect();
    let [a, b, c, own] = local.octets();
    for last in 1..=254 {
        if last != own {
            targets.insert(Ipv4Addr::new(a, b, c, last));
        }
    }
    let mut found: Vec<SmbServer> = stream::iter(targets)
        .map(|host| async move {
            match tokio::time::timeout(
                DISCOVERY_TIMEOUT,
                TcpStream::connect(SocketAddr::from((host, 445))),
            )
            .await
            {
                Ok(Ok(_)) => Some(SmbServer {
                    host: host.to_string(),
                }),
                _ => None,
            }
        })
        .buffer_unordered(48)
        .filter_map(|server| async move { server })
        .collect()
        .await;
    found.sort_by(|a, b| a.host.cmp(&b.host));
    found
}

/// List disk shares using SMB's srvsvc RPC. Some NAS devices intentionally
/// disable this RPC; callers should retain a manual-share fallback for those.
pub async fn list_shares(host: &str, user: &str, password: &str) -> Result<Vec<SmbShare>> {
    let addr = normalize_addr(host);
    let mut client = tokio::time::timeout(SETUP_TIMEOUT, smb2::connect(&addr, user, password))
        .await
        .context("smb connect timed out")?
        .context("smb connect")?;
    let shares = tokio::time::timeout(SETUP_TIMEOUT, client.list_shares())
        .await
        .context("smb share listing timed out")?
        .context("smb share listing")?;
    let mut out: Vec<SmbShare> = shares
        .into_iter()
        .map(|share| SmbShare {
            name: share.name,
            comment: share.comment,
        })
        .collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(out)
}

/// Return child directories for the authenticated share, for a file-manager
/// style folder picker. It deliberately reuses the one persistent session.
pub async fn list_directories(subdir: &str) -> Result<Vec<SmbDirectory>> {
    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let path = subdir.trim_matches('/').to_string();
    let mut guard = tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock())
        .await
        .context("smb session remained busy for too long")?;
    let entries = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.list_directory(tree, &path)).await
    }
    .context("smb directory listing timed out")?
    .context("smb directory listing")?;
    drop(guard);
    session.touch();
    let mut out: Vec<SmbDirectory> = entries
        .into_iter()
        .filter(|entry| entry.is_directory && entry.name != "." && entry.name != "..")
        .map(|entry| SmbDirectory {
            path: if path.is_empty() {
                entry.name.clone()
            } else {
                format!("{path}/{}", entry.name)
            },
            name: entry.name,
        })
        .collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(out)
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
            invalidate_session();
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
            invalidate_session();
            return Err(error).with_context(|| format!("smb list {smb_path}"));
        }
        Err(_) => {
            drop(guard);
            invalidate_session();
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

/// List external subtitle files sitting next to an SMB video: same directory,
/// subtitle extension, and file name starting with the video's stem (catches
/// `video.sc.ass` / `video.tc.ass` style multi-language pairs). Each hit is
/// registered on the proxy so mpv can load it over loopback HTTP.
pub async fn list_subtitles(smb_uri: &str) -> Result<Vec<crate::models::SubtitleCandidate>> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let (dir, video_name) = match path.rsplit_once('/') {
        Some((d, n)) => (d.to_string(), n.to_string()),
        None => (String::new(), path.clone()),
    };
    let stem = video_name
        .rsplit_once('.')
        .map(|(s, _)| s)
        .unwrap_or(&video_name);

    let c = creds().context("smb not connected")?;
    let session = session(&c).await?;
    let mut guard = match tokio::time::timeout(SETUP_TIMEOUT, session.inner.lock()).await {
        Ok(guard) => guard,
        Err(_) => {
            invalidate_session();
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
            invalidate_session();
            return Err(error).with_context(|| format!("smb list {dir}"));
        }
        Err(_) => {
            drop(guard);
            invalidate_session();
            anyhow::bail!("smb list {dir} timed out")
        }
    };
    drop(guard);

    let mut out = Vec::new();
    for e in entries {
        if e.is_directory || !is_subtitle(&e.name) || !e.name.starts_with(stem) {
            continue;
        }
        let sub_path = if dir.is_empty() {
            e.name.clone()
        } else {
            format!("{dir}/{}", e.name)
        };
        let sub_uri = format!("smb://{}/{}/{}", c.addr, c.share, sub_path);
        let url = register_playable(&sub_uri).await?;
        out.push(crate::models::SubtitleCandidate {
            file_name: e.name,
            uri: url,
        });
    }
    Ok(out)
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
            invalidate_session();
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let bytes = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.read_file(tree, &path)).await
    };
    drop(guard);
    let bytes = match bytes {
        Ok(bytes) => {
            session.touch();
            bytes
        }
        Err(_) => {
            invalidate_session();
            return Err(anyhow::anyhow!("smb read sidecar timed out"));
        }
    };
    // A read failure here is almost always "file not found" (no sidecar in this
    // folder), which is normal — treat it as an empty map, not an error.
    Ok(bytes.map(|b| crate::sidecar::parse(&b)).unwrap_or_default())
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
            invalidate_session();
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
            invalidate_session();
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
            invalidate_session();
            anyhow::bail!("smb session remained busy for too long")
        }
    };
    let res = {
        let SmbSessionInner { client, tree } = &mut *guard;
        tokio::time::timeout(SETUP_TIMEOUT, client.delete_file(tree, &path)).await
    };
    drop(guard);
    let res = match res {
        Ok(res) => {
            session.touch();
            res
        }
        Err(_) => {
            invalidate_session();
            anyhow::bail!("smb delete sidecar timed out")
        }
    };
    Ok(res.is_ok())
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

/// Get the persistent session, connecting on first use.
async fn session(c: &SmbCreds) -> Result<std::sync::Arc<SmbSession>> {
    if let Some(s) = SESSION.lock().unwrap().clone() {
        // Only rotate an idle connection if nothing is currently flowing
        // through the loopback proxy.  This keeps one stable SMB session for
        // normal playback, but avoids paying a 12-second stale-socket timeout
        // after the app has sat unused or backgrounded for a while.
        if !s.has_been_idle_too_long() || !ACTIVE_STREAMS.lock().unwrap().is_empty() {
            return Ok(s);
        }
        let mut cached = SESSION.lock().unwrap();
        if cached
            .as_ref()
            .is_some_and(|current| std::sync::Arc::ptr_eq(current, &s))
        {
            *cached = None;
        }
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
async fn open_session_reader(c: &SmbCreds, path: &str) -> Result<smb2::FileReader> {
    let mut last_error = None;
    for attempt in 0..2 {
        let sess = match session(c).await {
            Ok(s) => s,
            Err(e) => {
                last_error = Some(e);
                invalidate_session();
                continue;
            }
        };
        let guard = match tokio::time::timeout(SETUP_TIMEOUT, sess.inner.lock()).await {
            Ok(guard) => guard,
            Err(_) => {
                last_error = Some(anyhow::anyhow!("smb session remained busy for too long"));
                invalidate_session();
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
                return Ok(reader);
            }
            Ok(Err(e)) => last_error = Some(e.into()),
            Err(_) => last_error = Some(anyhow::anyhow!("smb open file timed out")),
        }
        invalidate_session();
        if attempt == 0 {
            continue;
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("smb open file failed")))
}

/// Drop the cached session. Called on a read/open failure (the connection is
/// presumed dead — NAS idle-closed it, network blip, credentials changed) so
/// the *next* request reconnects instead of repeatedly failing against a dead
/// handle. In-flight `FileReader`s are unaffected (each owns its own cloned
/// connection handle once opened).
fn invalidate_session() {
    *SESSION.lock().unwrap() = None;
}

/// Serializes proxy start-up so two concurrent `register_playable` calls don't
/// both bind a listener.
static PROXY_INIT: Mutex<()> = Mutex::new(());
static TOKEN_SEQ: AtomicU64 = AtomicU64::new(1);
/// Cancellation senders for in-flight proxy streams, keyed by a stream id.
/// Do not abort a task directly: `FileReader` needs async `close()` to release
/// its remote SMB handle, and forced task abort skips that cleanup.
static ACTIVE_STREAMS: Lazy<Mutex<HashMap<u64, tokio::sync::watch::Sender<bool>>>> =
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

/// Ask every active stream to finish its async SMB close before it exits.
/// Called whenever an episode token is released.
pub fn abort_all_streams() {
    let cancellations: Vec<tokio::sync::watch::Sender<bool>> = {
        let mut m = ACTIVE_STREAMS.lock().unwrap();
        m.drain().map(|(_, h)| h).collect()
    };
    for cancellation in cancellations {
        let _ = cancellation.send(true);
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
    if let Some(token) = url.rsplit('/').next() {
        PLAYABLE.lock().unwrap().remove(token);
    }
    // Release is called at the *start* of a switch (before the next file opens),
    // so tear down every lingering stream from the file we're leaving. This is
    // the active fix for the cross-folder freeze: don't wait for old connections
    // to drain (a passive timeout) — close them now so the next open has free
    // NAS sessions to work with.
    abort_all_streams();
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
                    let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
                    // serve() runs on PROXY_RT (current runtime), isolated from RT.
                    let jh = tokio::spawn(async move {
                        let _ = serve(stream, cancel_rx).await;
                        ACTIVE_STREAMS.lock().unwrap().remove(&id);
                    });
                    // Keep the task detached: it must be allowed to close the
                    // remote reader after receiving a cancellation signal.
                    drop(jh);
                    ACTIVE_STREAMS.lock().unwrap().insert(id, cancel_tx);
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
async fn serve(
    mut stream: TcpStream,
    mut cancelled: tokio::sync::watch::Receiver<bool>,
) -> Result<()> {
    // Read headers (until CRLFCRLF). Video requests are tiny, 8KB is plenty.
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = tokio::select! {
            _ = cancelled.changed() => return Ok(()),
            n = stream.read(&mut tmp) => n?,
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
    let mut range: Option<(u64, Option<u64>)> = None;
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
    let reader = match open_session_reader(&c, &path).await {
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

    let (start, end) = match range {
        Some((s, Some(e))) => (s, e.min(total.saturating_sub(1))),
        Some((s, None)) => (s, total.saturating_sub(1)),
        None => (0, total.saturating_sub(1)),
    };
    if start >= total {
        let _ = reader.close().await;
        let _ = stream
            .write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await;
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
                invalidate_session();
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
fn mime_for_path(path: &str) -> &'static str {
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
        _ => "video/*",
    }
}

/// Parse a `bytes=start-end` Range header value into (start, Option<end>).
fn parse_range(v: &str) -> Option<(u64, Option<u64>)> {
    let v = v.strip_prefix("bytes=")?;
    let (s, e) = v.split_once('-')?;
    let start: u64 = s.trim().parse().ok()?;
    let end = e.trim();
    let end = if end.is_empty() {
        None
    } else {
        Some(end.parse().ok()?)
    };
    Some((start, end))
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

fn is_cancelled(smb_uri: &str) -> bool {
    DOWNLOAD_CANCELLED.lock().unwrap().contains(smb_uri)
}

/// Download an SMB file into `dest_dir`, reporting progress via `progress`.
/// Writes to `<name>.part` and renames on completion so an interrupted download
/// never masquerades as a finished file. Returns the final local path.
pub async fn download(
    smb_uri: &str,
    dest_dir: &str,
    progress: impl Fn(u64, u64),
) -> Result<String> {
    DOWNLOAD_CANCELLED.lock().unwrap().remove(smb_uri);
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let file_name = path.rsplit('/').next().unwrap_or(&path).to_string();
    let c = creds().context("smb not connected")?;
    // Downloads used to establish a second TCP/authenticated SMB session even
    // while the proxy was playing. Many NASes limit sessions or open handles
    // per client; reuse the same multiplexed session as the proxy instead.
    let _permit = SMB_CONN.acquire().await;
    let reader = open_session_reader(&c, &path).await?;
    let total = reader.size();

    // A zero-length video is never a valid completed download. Previously the
    // loop below was skipped and a zero-byte file was recorded as successful,
    // which is exactly the "instant completion but no file" symptom on iOS.
    if total == 0 {
        let _ = reader.close().await;
        anyhow::bail!("SMB reported this video as 0 bytes; download was not saved");
    }

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
    let mut out = tokio::fs::File::create(&part_path)
        .await
        .context("create .part file")?;

    const CHUNK: u64 = 1024 * 1024;
    let mut off: u64 = 0;
    let transfer_result: Result<()> = async {
        while off < total {
            if is_cancelled(smb_uri) {
                anyhow::bail!("下载已取消");
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
                    invalidate_session();
                    return Err(error).context("smb read");
                }
                Err(_) => {
                    invalidate_session();
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
