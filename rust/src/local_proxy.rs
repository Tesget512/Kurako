//! Loopback HTTP streaming for sandboxed local files (used on macOS).
//!
//! Why this exists: with the App Sandbox enabled, an NSOpenPanel grant or even
//! a security-scoped bookmark lets THIS process read the folder through Rust
//! `std::fs` (library scanning proves it), but libmpv's own path-based `open()`
//! is still denied by the kernel (`file-read-data` on the volume root during
//! path resolution). The `fd://N` pseudo-protocol does not help either: mpv
//! accepts the descriptor but media_kit's mpv build cannot probe the demuxer
//! from it ("Failed to recognize file format"). So we serve the bytes over the
//! same kind of Range-capable loopback HTTP server that SMB/WebDAV playback
//! already uses — mpv's HTTP path is its best-tested input and needs no file
//! access at all.
//!
//! The security scope stays active for the whole playback (held by the Dart
//! side), so each request re-opens the file with plain `std::fs::File::open`;
//! per-request opens keep the implementation stateless and let Range requests
//! seek independently. No session/reconnect machinery is needed — unlike the
//! SMB proxy there is no remote side.

use anyhow::{bail, Context, Result};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::io::SeekFrom;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::Mutex;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// token -> local file path. Registered by `register_playable`.
static PLAYABLE: Lazy<Mutex<HashMap<String, PathBuf>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// The port the proxy bound to (0 = not started yet).
static PROXY_PORT: AtomicU16 = AtomicU16::new(0);
static PROXY_INIT: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

/// Dedicated runtime for the accept loop + serve tasks, isolated from the
/// shared `RT` for the same reason as the SMB proxy: streaming work must never
/// starve the `block_on` calls the UI waits on. Two threads are plenty —
/// serving a local file is bounded by disk, not by a network session.
static PROXY_RT: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("local-proxy")
        .enable_all()
        .build()
        .expect("local proxy runtime")
});

/// Register a local file for playback and return `http://127.0.0.1:port/<token>`.
/// Starts the proxy on first use. Fails fast when the file is not readable, so
/// the caller surfaces a concrete error instead of an mpv spinner.
pub fn register_playable(path: &str) -> Result<String> {
    let metadata = std::fs::metadata(path).context("读取本地视频文件信息")?;
    // A directory passes metadata() and File::open(), then read() fails with
    // EISDIR after the response headers were already sent — the client sees an
    // empty 200/206 and no error. Reject it here so the caller reports a real
    // problem instead of a silent zero-byte stream.
    if !metadata.is_file() {
        bail!("本地播放路径不是文件");
    }
    if metadata.len() == 0 {
        bail!("本地视频文件为空");
    }
    let port = ensure_proxy()?;
    // Unpredictable token: the listener is loopback-only but unauthenticated,
    // so a sequential counter would let any local process walk the ids and
    // stream whatever is currently playing.
    let token = random_token();
    PLAYABLE
        .lock()
        .unwrap()
        .insert(token.clone(), PathBuf::from(path));
    Ok(format!("http://127.0.0.1:{port}/{token}"))
}

/// 128 random bits, hex encoded.
fn random_token() -> String {
    let mut bytes = [0u8; 16];
    // OsRng is infallible for this size on every supported platform.
    let _ = getrandom::getrandom(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Drop a previously registered token (called when playback ends). Tolerates
/// any loopback URL — unknown tokens are simply ignored, so the shared
/// `release_network_url` entry point can call every backend unconditionally.
pub fn unregister_playable(url: &str) {
    if let Some(token) = url.rsplit('/').next() {
        PLAYABLE.lock().unwrap().remove(token);
    }
}

/// Start the loopback HTTP server once (on the dedicated `PROXY_RT`); returns
/// its port. Synchronous: binds with std then hands the listener to `PROXY_RT`.
fn ensure_proxy() -> Result<u16> {
    let existing = PROXY_PORT.load(Ordering::Acquire);
    if existing != 0 {
        return Ok(existing);
    }
    let _guard = PROXY_INIT.lock().unwrap();
    let existing = PROXY_PORT.load(Ordering::Acquire);
    if existing != 0 {
        return Ok(existing);
    }
    let std_listener = std::net::TcpListener::bind("127.0.0.1:0").context("bind local proxy")?;
    std_listener
        .set_nonblocking(true)
        .context("local proxy listener nonblocking")?;
    let port = std_listener.local_addr()?.port();
    PROXY_PORT.store(port, Ordering::Release);
    PROXY_RT.spawn(async move {
        let listener = match TcpListener::from_std(std_listener) {
            Ok(l) => l,
            Err(_) => {
                PROXY_PORT.store(0, Ordering::Release);
                return;
            }
        };
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    // Detached: a superseded stream stops itself via the token
                    // check between chunks; no per-stream bookkeeping needed.
                    let jh = tokio::spawn(async move {
                        let _ = serve(stream).await;
                    });
                    drop(jh);
                }
                Err(error) => {
                    // EMFILE/ENFILE and friends are transient: a burst of
                    // connections must not permanently kill the listener and
                    // invalidate every URL already handed to mpv.
                    if is_transient_accept_error(&error) {
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                        continue;
                    }
                    PROXY_PORT.store(0, Ordering::Release);
                    break;
                }
            }
        }
    });
    Ok(port)
}

fn is_transient_accept_error(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::Interrupted
            | std::io::ErrorKind::WouldBlock
            | std::io::ErrorKind::OutOfMemory
    ) || matches!(error.raw_os_error(), Some(24) | Some(23)) // EMFILE, ENFILE
}

/// Handle one HTTP request: parse the token + optional Range, stream the file.
async fn serve(mut stream: TcpStream) -> Result<()> {
    // Read headers (until CRLFCRLF). Video requests are tiny, 16KB is plenty.
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
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 16384 {
            // Refuse to parse a truncated header block as if it were complete.
            let _ = stream
                .write_all(
                    b"HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            return Ok(());
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or("");
    // mpv may probe HTTP sources with HEAD before opening a GET stream; a HEAD
    // must get headers only (see the SMB proxy for the same behaviour).
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or("GET");
    let token = request_parts
        .next()
        .unwrap_or("/")
        .trim_start_matches('/')
        .to_string();
    let mut range: Option<ByteRange> = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("range") {
            range = parse_range(value.trim());
        }
    }

    let path = PLAYABLE.lock().unwrap().get(&token).cloned();
    let Some(path) = path else {
        let _ = stream
            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await;
        return Ok(());
    };

    // The scope that makes this open succeed is held by the Dart side for the
    // whole playback. A failure here means the volume went away mid-play —
    // surface it as a clean HTTP error instead of hanging the client.
    //
    // tokio::fs keeps these syscalls off the two worker threads: an external
    // drive spinning up (or retrying a bad sector) can block for seconds, and
    // two blocked workers would also stop the accept loop.
    let mut file = match tokio::fs::File::open(&path).await {
        Ok(file) => file,
        Err(e) => {
            write_http_error(&mut stream, "500 Local Open Failed", &format!("{e:#}")).await;
            return Ok(());
        }
    };
    let total = match file.metadata().await {
        Ok(meta) => meta.len(),
        Err(e) => {
            write_http_error(&mut stream, "500 Local Stat Failed", &format!("{e:#}")).await;
            return Ok(());
        }
    };
    if total == 0 {
        write_http_error(&mut stream, "404 Empty File", "zero-byte local video file").await;
        return Ok(());
    }

    // Resolve the range against the file size, mirroring the SMB proxy: an
    // inverted range is syntactically invalid per RFC 7233 and MUST be ignored
    // (served as 200); a suffix range asks for the last n bytes.
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
        let response = format!(
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        let _ = stream.write_all(response.as_bytes()).await;
        return Ok(());
    }
    let len = end.saturating_sub(start) + 1;

    let status = if range.is_some() {
        "HTTP/1.1 206 Partial Content"
    } else {
        "HTTP/1.1 200 OK"
    };
    let content_type = crate::smb::mime_for_path(&path.to_string_lossy());
    let mut header = format!(
        "{status}\r\nContent-Type: {content_type}\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\nConnection: close\r\n"
    );
    if range.is_some() {
        header.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    }
    header.push_str("\r\n");
    if stream.write_all(header.as_bytes()).await.is_err() {
        return Ok(());
    }
    if method.eq_ignore_ascii_case("HEAD") {
        return Ok(());
    }

    // Stream in chunks from disk. tokio::fs performs the blocking syscall on a
    // blocking pool thread, so a slow external drive cannot stall the accept
    // loop or a concurrent probe on the other worker thread.
    const CHUNK: usize = 256 * 1024;
    let mut chunk = vec![0u8; CHUNK];
    if file.seek(SeekFrom::Start(start)).await.is_err() {
        return Ok(());
    }
    let mut remaining = len;
    while remaining > 0 {
        // Stop as soon as this stream's token is released (episode/anime
        // switch unregisters it): the same cheap check the SMB proxy uses.
        if !PLAYABLE.lock().unwrap().contains_key(&token) {
            break;
        }
        let want = (CHUNK as u64).min(remaining) as usize;
        let n = match file.read(&mut chunk[..want]).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => break,
        };
        if stream.write_all(&chunk[..n]).await.is_err() {
            break;
        }
        remaining -= n as u64;
    }
    Ok(())
}

async fn write_http_error(stream: &mut TcpStream, status: &str, detail: &str) {
    let body = detail.as_bytes();
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.write_all(body).await;
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
/// (mpv uses it to probe an mp4's trailing moov atom).
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::sync::atomic::{AtomicU64 as TestSeq, Ordering as TestOrdering};

    static FILE_SEQ: TestSeq = TestSeq::new(1);

    fn temp_video(content: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "kurako-local-proxy-test-{}-{}.mkv",
            std::process::id(),
            FILE_SEQ.fetch_add(1, TestOrdering::Relaxed)
        ));
        std::fs::write(&path, content).unwrap();
        path
    }

    /// Issue one HTTP request against a fresh registration and return
    /// (status line, headers, body).
    fn request(path: &PathBuf, extra: &str, method: &str) -> (String, String, Vec<u8>) {
        let url = register_playable(path.to_str().unwrap()).unwrap();
        let port = url
            .strip_prefix("http://127.0.0.1:")
            .unwrap()
            .split('/')
            .next()
            .unwrap()
            .parse::<u16>()
            .unwrap();
        let token = url.rsplit('/').next().unwrap().to_string();
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        let head = format!("{method} /{token} HTTP/1.1\r\nHost: 127.0.0.1\r\n{extra}\r\n");
        std::io::Write::write_all(&mut stream, head.as_bytes()).unwrap();
        // Connection: close — read to EOF for GET; for HEAD the response ends
        // with the header terminator.
        let mut raw = Vec::new();
        std::io::Read::read_to_end(&mut stream, &mut raw).unwrap();
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("header terminator");
        let head_text = String::from_utf8_lossy(&raw[..split]).to_string();
        let mut head_lines = head_text.lines();
        let status = head_lines.next().unwrap_or("").to_string();
        let headers = head_lines.collect::<Vec<_>>().join("\n");
        let body = raw[split + 4..].to_vec();
        unregister_playable(&url);
        (status, headers, body)
    }

    #[test]
    fn full_get_serves_whole_file() {
        let content: Vec<u8> = (0..700_000u32).map(|i| (i % 251) as u8).collect();
        let path = temp_video(&content);
        let (status, headers, body) = request(&path, "", "GET");
        assert_eq!(status, "HTTP/1.1 200 OK");
        assert!(headers.contains("Accept-Ranges: bytes"));
        assert!(headers.contains("Content-Type: video/x-matroska"));
        assert_eq!(body, content);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn range_get_returns_206_slice() {
        let content: Vec<u8> = (0..100_000u32).map(|i| (i % 253) as u8).collect();
        let path = temp_video(&content);
        let (status, headers, body) = request(&path, "Range: bytes=1000-1999\r\n", "GET");
        assert_eq!(status, "HTTP/1.1 206 Partial Content");
        assert!(headers.contains("Content-Range: bytes 1000-1999/100000"));
        assert_eq!(body, &content[1000..2000]);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn suffix_range_returns_tail() {
        let content: Vec<u8> = (0..50_000u32).map(|i| (i % 241) as u8).collect();
        let path = temp_video(&content);
        let (status, _headers, body) = request(&path, "Range: bytes=-100\r\n", "GET");
        assert_eq!(status, "HTTP/1.1 206 Partial Content");
        assert_eq!(body, &content[content.len() - 100..]);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn inverted_range_falls_back_to_full_200() {
        let content = vec![7u8; 10_000];
        let path = temp_video(&content);
        let (status, _headers, body) = request(&path, "Range: bytes=900-100\r\n", "GET");
        assert_eq!(status, "HTTP/1.1 200 OK");
        assert_eq!(body, content);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn out_of_range_returns_416() {
        let content = vec![3u8; 1_000];
        let path = temp_video(&content);
        let (status, headers, body) = request(&path, "Range: bytes=5000-\r\n", "GET");
        assert_eq!(status, "HTTP/1.1 416 Range Not Satisfiable");
        assert!(headers.contains("Content-Range: bytes */1000"));
        assert!(body.is_empty());
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn head_returns_headers_without_body() {
        let content = vec![9u8; 2_048];
        let path = temp_video(&content);
        let (status, headers, body) = request(&path, "", "HEAD");
        assert_eq!(status, "HTTP/1.1 200 OK");
        assert!(headers.contains("Content-Length: 2048"));
        assert!(body.is_empty());
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn released_token_returns_404() {
        let path = temp_video(&vec![1u8; 512]);
        let url = register_playable(path.to_str().unwrap()).unwrap();
        unregister_playable(&url);
        let port = url
            .strip_prefix("http://127.0.0.1:")
            .unwrap()
            .split('/')
            .next()
            .unwrap()
            .parse::<u16>()
            .unwrap();
        let token = url.rsplit('/').next().unwrap();
        let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        std::io::Write::write_all(
            &mut stream,
            format!("GET /{token} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").as_bytes(),
        )
        .unwrap();
        let mut reader = BufReader::new(stream);
        let mut status = String::new();
        reader.read_line(&mut status).unwrap();
        assert_eq!(status.trim(), "HTTP/1.1 404 Not Found");
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn register_rejects_missing_and_empty_files() {
        let missing = std::env::temp_dir().join("kurako-local-proxy-missing.mkv");
        assert!(register_playable(missing.to_str().unwrap()).is_err());
        let empty = temp_video(&[]);
        assert!(register_playable(empty.to_str().unwrap()).is_err());
        std::fs::remove_file(empty).ok();
    }

    /// A directory used to register successfully, then serve headers with no
    /// body (EISDIR on read), which looked like a hang to the caller.
    #[test]
    fn register_rejects_directories() {
        let dir =
            std::env::temp_dir().join(format!("kurako-local-proxy-dir-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let error = register_playable(dir.to_str().unwrap()).unwrap_err();
        assert!(error.to_string().contains("不是文件"), "{error}");
        std::fs::remove_dir(dir).ok();
    }
}
