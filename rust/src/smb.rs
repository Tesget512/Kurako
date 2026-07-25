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
use std::collections::HashMap;
use std::sync::atomic::{AtomicU16, AtomicU64, Ordering};
use std::sync::Mutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

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
    // Credentials changed (reconnect/reconfigure) — drop any persistent proxy
    // session so the next stream reconnects under the current creds instead of
    // reusing one tied to the old (possibly now-invalid) ones.
    invalidate_session();
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

/// Test-connect with the given credentials and cache them on success.
pub async fn connect(host: &str, share: &str, user: &str, password: &str) -> Result<()> {
    let c = SmbCreds {
        addr: normalize_addr(host),
        share: share.trim().trim_matches('/').to_string(),
        user: user.to_string(),
        password: password.to_string(),
    };
    // A busy SMB server can briefly reject a second session while it reaps an
    // old one. Retrying this *initial* connection once avoids presenting the
    // cryptic bare "smb connect" error after a player/download was just
    // stopped, without leaving the UI blocked indefinitely.
    let mut last_error = None;
    for attempt in 0..2 {
        match open(&c).await {
            Ok((mut client, mut tree)) => {
                // A root listing proves auth + share access work; unlike the
                // old code, do not silently accept a failed list operation.
                let listed = client.list_directory(&mut tree, "").await;
                let _ = client.disconnect_share(&tree).await;
                match listed {
                    Ok(_) => {
                        set_creds(Some(c));
                        return Ok(());
                    }
                    Err(e) => last_error = Some(e.into()),
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
    let (mut client, mut tree) = open(&c).await?;
    let entries = client
        .list_directory(&mut tree, &dir)
        .await
        .with_context(|| format!("smb list {dir}"))?;
    let _ = client.disconnect_share(&tree).await;

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
    let (mut client, mut tree) = open(&c).await?;
    let bytes = client.read_file(&mut tree, &path).await;
    let _ = client.disconnect_share(&tree).await;
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
    let (mut client, mut tree) = open(&c).await?;
    let data = crate::sidecar::serialize(map);
    let res = client.write_file(&mut tree, &path, &data).await;
    let _ = client.disconnect_share(&tree).await;
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
    let (mut client, mut tree) = open(&c).await?;
    let res = client.delete_file(&mut tree, &path).await;
    let _ = client.disconnect_share(&tree).await;
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

/// Cap concurrent reads the proxy issues against the shared session at once —
/// now a plain concurrency throttle (the connection itself is reused, see
/// [SESSION]), not a connection-count limiter. Old streams are aborted on
/// switch, releasing their permits promptly.
static SMB_CONN: Lazy<tokio::sync::Semaphore> = Lazy::new(|| tokio::sync::Semaphore::new(6));

/// One persistent, authenticated SMB2 connection + tree, reused across every
/// proxy stream instead of connecting fresh per HTTP request. This mirrors how
/// Windows' own SMB redirector serves a UNC path — one session per share for
/// the whole app lifetime — and is the fix for the "切换次数多了会卡住几秒"
/// symptom: previously `serve()` called `open()` (full TCP + negotiate +
/// session-setup + tree-connect) for *every* proxy request, and libmpv issues
/// several requests per single episode open (probe, moov/index read, each
/// seek's Range) — so normal viewing, not just rapid switching, kept opening
/// fresh SMB sessions against the NAS, which eventually hit its per-client
/// session cap and stalled new connects for a few seconds until it reaped old
/// ones. `SmbClient::open_file_reader`/`FileReader::read_at` only need `&self`
/// (the crate's `Connection` is an actor-backed, cheaply-cloneable handle
/// designed for concurrent multiplexed requests — see its `pipeline` module),
/// so many concurrent reads through one shared session is a supported,
/// intended usage, not a workaround.
struct SmbSession {
    client: smb2::SmbClient,
    tree: smb2::Tree,
}
static SESSION: Mutex<Option<std::sync::Arc<SmbSession>>> = Mutex::new(None);
/// Serializes session (re)establishment so a burst of concurrent proxy
/// requests (e.g. mpv's initial multi-range probe) pays for one handshake, not
/// N racing ones.
static SESSION_INIT: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

/// Get the persistent session, connecting on first use.
async fn session(c: &SmbCreds) -> Result<std::sync::Arc<SmbSession>> {
    if let Some(s) = SESSION.lock().unwrap().clone() {
        return Ok(s);
    }
    let _guard = SESSION_INIT.lock().await;
    // Re-check: another caller may have connected while we waited for the lock.
    if let Some(s) = SESSION.lock().unwrap().clone() {
        return Ok(s);
    }
    let (client, tree) = open(c).await?;
    let s = std::sync::Arc::new(SmbSession { client, tree });
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
        match tokio::time::timeout(
            SETUP_TIMEOUT,
            sess.client.open_file_reader(&sess.tree, path),
        )
        .await
        {
            Ok(Ok(reader)) => return Ok(reader),
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
/// Abort handles for in-flight proxy stream tasks, keyed by a per-stream id.
/// A folder/episode switch forcibly aborts these so the *previous* file's SMB
/// connections close immediately instead of lingering — stale streams piling up
/// against the NAS's per-client session limit is what freezes the next open
/// (the cross-folder freeze). The map is drained on every switch, so the rare
/// already-finished entry (task removed itself before we inserted) is harmless.
static ACTIVE_STREAMS: Lazy<Mutex<HashMap<u64, tokio::task::AbortHandle>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static STREAM_SEQ: AtomicU64 = AtomicU64::new(1);

/// Forcibly abort every in-flight proxy stream. Aborting a task drops its future,
/// which drops the smb2 client and closes its TCP connection to the NAS, freeing
/// the session right away. Called whenever a token is released (i.e. on switch).
pub fn abort_all_streams() {
    let handles: Vec<tokio::task::AbortHandle> = {
        let mut m = ACTIVE_STREAMS.lock().unwrap();
        m.drain().map(|(_, h)| h).collect()
    };
    for h in handles {
        h.abort();
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
    let existing = PROXY_PORT.load(Ordering::Relaxed);
    if existing != 0 {
        return Ok(existing);
    }
    let _guard = PROXY_INIT.lock().unwrap();
    // Re-check under the lock: another caller may have started it while we waited.
    let existing = PROXY_PORT.load(Ordering::Relaxed);
    if existing != 0 {
        return Ok(existing);
    }
    let std_listener = std::net::TcpListener::bind("127.0.0.1:0").context("bind proxy")?;
    std_listener
        .set_nonblocking(true)
        .context("proxy listener nonblocking")?;
    let port = std_listener.local_addr()?.port();
    PROXY_RT.spawn(async move {
        let listener = match TcpListener::from_std(std_listener) {
            Ok(l) => l,
            Err(_) => return,
        };
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let id = STREAM_SEQ.fetch_add(1, Ordering::Relaxed);
                    // serve() runs on PROXY_RT (current runtime), isolated from RT.
                    let jh = tokio::spawn(async move {
                        let _ = serve(stream).await;
                        ACTIVE_STREAMS.lock().unwrap().remove(&id);
                    });
                    ACTIVE_STREAMS.lock().unwrap().insert(id, jh.abort_handle());
                }
                Err(_) => break,
            }
        }
    });
    PROXY_PORT.store(port, Ordering::Relaxed);
    Ok(port)
}

/// Handle one HTTP request: parse the token + optional Range, stream the file.
async fn serve(mut stream: TcpStream) -> Result<()> {
    // Read headers (until CRLFCRLF). Video requests are tiny, 8KB is plenty.
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = stream.read(&mut tmp).await?;
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

    // Bound concurrent reads against the shared session (see [SMB_CONN]). On a
    // switch the old streams are aborted, which drops their permits, so the new
    // file's streams get in promptly instead of a burst piling up.
    let _permit = SMB_CONN.acquire().await;

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
    stream.write_all(header.as_bytes()).await?;
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
        let data = match tokio::time::timeout(
            std::time::Duration::from_secs(30),
            reader.read_at(off, want),
        )
        .await
        {
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
            let data = reader.read_at(off, want).await.context("smb read")?;
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
