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
static TOKEN_SEQ: AtomicU64 = AtomicU64::new(1);

/// Register an SMB URI for playback and return `http://127.0.0.1:port/<token>`.
/// Starts the proxy on first use. Must be called from within the tokio runtime.
pub async fn register_playable(smb_uri: &str) -> Result<String> {
    let path = smb_path_from_uri(smb_uri).context("bad smb uri")?;
    let port = ensure_proxy().await?;
    let token = format!("t{}", TOKEN_SEQ.fetch_add(1, Ordering::Relaxed));
    PLAYABLE.lock().unwrap().insert(token.clone(), path);
    Ok(format!("http://127.0.0.1:{port}/{token}"))
}

/// Drop a previously registered token (called when playback ends).
pub fn unregister_playable(url: &str) {
    if let Some(token) = url.rsplit('/').next() {
        PLAYABLE.lock().unwrap().remove(token);
    }
}

/// Start the loopback HTTP server once; returns its port.
async fn ensure_proxy() -> Result<u16> {
    let existing = PROXY_PORT.load(Ordering::Relaxed);
    if existing != 0 {
        return Ok(existing);
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.context("bind proxy")?;
    let port = listener.local_addr()?.port();
    PROXY_PORT.store(port, Ordering::Relaxed);
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    tokio::spawn(async move {
                        let _ = serve(stream).await;
                    });
                }
                Err(_) => break,
            }
        }
    });
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
    // "GET /<token> HTTP/1.1"
    let token = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .trim_start_matches('/')
        .to_string();
    let mut range: Option<(u64, Option<u64>)> = None;
    for line in lines {
        if let Some(v) = line.strip_prefix("Range:").or_else(|| line.strip_prefix("range:")) {
            range = parse_range(v.trim());
        }
    }

    let path = PLAYABLE.lock().unwrap().get(&token).cloned();
    let Some(path) = path else {
        let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await;
        return Ok(());
    };

    let Some(c) = creds() else {
        let _ = stream.write_all(b"HTTP/1.1 500 No SMB\r\nContent-Length: 0\r\n\r\n").await;
        return Ok(());
    };

    // Open a dedicated connection + reader for this request.
    let mut client = smb2::connect(&c.addr, &c.user, &c.password).await?;
    let tree = client.connect_share(&c.share).await?;
    let reader = client.open_file_reader(&tree, &path).await?;
    let total = reader.size();

    let (start, end) = match range {
        Some((s, Some(e))) => (s, e.min(total.saturating_sub(1))),
        Some((s, None)) => (s, total.saturating_sub(1)),
        None => (0, total.saturating_sub(1)),
    };
    let len = end.saturating_sub(start) + 1;

    // Response headers.
    let status = if range.is_some() {
        "HTTP/1.1 206 Partial Content"
    } else {
        "HTTP/1.1 200 OK"
    };
    let mut header = format!(
        "{status}\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\n"
    );
    if range.is_some() {
        header.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    }
    header.push_str("\r\n");
    stream.write_all(header.as_bytes()).await?;

    // Stream in chunks from the share.
    const CHUNK: u64 = 256 * 1024;
    let mut off = start;
    while off <= end {
        let want = CHUNK.min(end - off + 1);
        let data = match reader.read_at(off, want).await {
            Ok(d) => d,
            Err(_) => break,
        };
        if data.is_empty() {
            break;
        }
        if stream.write_all(&data).await.is_err() {
            break; // client disconnected (seek / closed)
        }
        off += data.len() as u64;
    }
    let _ = client.disconnect_share(&tree).await;
    Ok(())
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
