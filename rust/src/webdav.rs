//! Authenticated WebDAV media source backed by reqwest/rustls.
//!
//! Directory enumeration uses bounded Depth:1 PROPFIND calls. Playback is
//! exposed through a loopback HTTP proxy so credentials never enter media URLs
//! and Digest authentication remains usable by libmpv. Servers must honor byte
//! ranges; otherwise Kurako reports that streaming is unsupported instead of
//! pretending seek is safe.

use crate::models::{RemoteEntry, ScannedFile, SubtitleCandidate};
use anyhow::{Context, Result};
use futures::StreamExt;
use once_cell::sync::Lazy;
use percent_encoding::percent_decode_str;
use reqwest::header::{CONTENT_RANGE, CONTENT_TYPE, RANGE};
use reqwest::{Method, StatusCode, Url};
use reqwest_dav::types::list_cmd::{ListMultiStatus, ListResponse};
use reqwest_dav::{Auth, Client, ClientBuilder, Depth};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU16, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const SETUP_TIMEOUT: Duration = Duration::from_secs(15);
const READ_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_ENUMERATED_ENTRIES: usize = 200_000;
const MAX_PROPFIND_BYTES: usize = 8 * 1024 * 1024;
const SETUP_PROFILE_LIFETIME: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebDavCreds {
    pub base_url: String,
    pub user: String,
    pub password: String,
    /// `anonymous` | `basic`
    pub auth_mode: String,
    /// Explicit opt-in for private-LAN servers with invalid/self-signed TLS.
    /// This disables certificate validation, so it must never be the default.
    pub allow_insecure_tls: bool,
}

static CREDS: Lazy<Mutex<Option<WebDavCreds>>> = Lazy::new(|| Mutex::new(None));
static CLIENT: Lazy<Mutex<Option<(WebDavCreds, Client)>>> = Lazy::new(|| Mutex::new(None));
/// Total response-body bytes successfully delivered by the loopback playback
/// proxy. HEAD probes, HTTP headers, downloads, and failed socket writes are
/// deliberately excluded so Dart can derive the actual playback throughput.
static BYTES_SERVED: AtomicU64 = AtomicU64::new(0);

/// Cumulative bytes served by the WebDAV playback proxy since process start.
pub fn proxy_bytes_served() -> u64 {
    BYTES_SERVED.load(Ordering::Relaxed)
}

pub(crate) fn maintenance_read_is_busy() -> bool {
    !PLAYABLE.lock().unwrap().is_empty() || ACTIVE_TRANSFERS.load(Ordering::Acquire) > 0
}

#[derive(Clone)]
struct SetupProfile {
    creds: WebDavCreds,
    client: Client,
    created_at: Instant,
}

static SETUP_PROFILES: Lazy<Mutex<HashMap<String, SetupProfile>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_SETUP_ID: AtomicU64 = AtomicU64::new(1);

pub fn set_creds(creds: Option<WebDavCreds>) -> Result<()> {
    let creds = creds.map(validate_creds).transpose()?;
    ensure_configuration_can_change(creds.as_ref())?;
    *CREDS.lock().unwrap() = creds;
    *CLIENT.lock().unwrap() = None;
    clear_playable();
    Ok(())
}

fn validate_creds(mut creds: WebDavCreds) -> Result<WebDavCreds> {
    let mut base = Url::parse(creds.base_url.trim()).context("WebDAV 地址无效")?;
    if base.scheme() != "http" && base.scheme() != "https" {
        anyhow::bail!("WebDAV 仅支持 http:// 或 https:// 地址");
    }
    if !base.username().is_empty() || base.password().is_some() {
        anyhow::bail!("请在凭证栏填写 WebDAV 用户名和密码，不要写入地址");
    }
    base.set_query(None);
    base.set_fragment(None);
    if !base.path().ends_with('/') {
        let path = format!("{}/", base.path());
        base.set_path(&path);
    }
    if !matches!(creds.auth_mode.as_str(), "anonymous" | "basic") {
        anyhow::bail!("未知 WebDAV 认证方式");
    }
    // The option has no meaning for clear-text HTTP. Normalizing it prevents
    // two otherwise-identical HTTP profiles from producing separate clients.
    if base.scheme() != "https" {
        creds.allow_insecure_tls = false;
    }
    creds.base_url = base.to_string();
    Ok(creds)
}

fn creds() -> Result<WebDavCreds> {
    CREDS.lock().unwrap().clone().context("WebDAV 尚未配置")
}

fn ensure_configuration_can_change(next: Option<&WebDavCreds>) -> Result<()> {
    if CREDS.lock().unwrap().as_ref() == next {
        return Ok(());
    }
    if !PLAYABLE.lock().unwrap().is_empty() || ACTIVE_TRANSFERS.load(Ordering::Acquire) > 0 {
        anyhow::bail!("WebDAV 正在播放或下载，请结束后再切换服务器");
    }
    Ok(())
}

fn client() -> Result<(WebDavCreds, Client)> {
    let creds = creds()?;
    if let Some((cached_creds, cached_client)) = CLIENT.lock().unwrap().as_ref() {
        if cached_creds == &creds {
            return Ok((creds, cached_client.clone()));
        }
    }
    let dav = build_client(&creds)?;
    *CLIENT.lock().unwrap() = Some((creds.clone(), dav.clone()));
    Ok((creds, dav))
}

fn build_client(creds: &WebDavCreds) -> Result<Client> {
    let agent = reqwest::ClientBuilder::new()
        .connect_timeout(SETUP_TIMEOUT)
        .redirect(reqwest::redirect::Policy::limited(5))
        .danger_accept_invalid_certs(creds.allow_insecure_tls)
        .build()
        .context("创建 WebDAV HTTP 客户端")?;
    let auth = match creds.auth_mode.as_str() {
        "anonymous" => Auth::Anonymous,
        _ => Auth::Basic(creds.user.clone(), creds.password.clone()),
    };
    let dav = ClientBuilder::new()
        .set_agent(agent)
        .set_host(creds.base_url.clone())
        .set_auth(auth)
        .build()
        .context("创建 WebDAV 客户端")?;
    Ok(dav)
}

pub async fn test_connection() -> Result<Vec<RemoteEntry>> {
    list_entries("").await
}

pub async fn list_entries(subdir: &str) -> Result<Vec<RemoteEntry>> {
    let (creds, client) = client()?;
    list_entries_with(&creds, &client, subdir).await
}

async fn list_entries_with(
    creds: &WebDavCreds,
    client: &Client,
    subdir: &str,
) -> Result<Vec<RemoteEntry>> {
    let requested = normalize_relative(subdir)?;
    let encoded = encoded_relative(&requested);
    let response = tokio::time::timeout(SETUP_TIMEOUT, client.list_raw(&encoded, Depth::Number(1)))
        .await
        .context("WebDAV 目录连接超时")?
        .map_err(|error| webdav_transport_error(&creds.base_url, error))?;
    if response.status() != StatusCode::MULTI_STATUS {
        anyhow::bail!("WebDAV PROPFIND 返回 HTTP {}", response.status());
    }
    let body = read_response_limited(response, MAX_PROPFIND_BYTES, SETUP_TIMEOUT).await?;
    validate_listing_properties(&body)?;
    let responses = serde_xml_rs::from_reader::<_, ListMultiStatus>(body.as_slice())
        .context("WebDAV PROPFIND XML 无效")?
        .responses;
    entries_from_responses(&creds, &requested, responses)
}

pub async fn setup_begin(
    base_url: &str,
    user: &str,
    password: &str,
    auth_mode: &str,
    allow_insecure_tls: bool,
) -> Result<String> {
    let creds = validate_creds(WebDavCreds {
        base_url: base_url.to_string(),
        user: user.to_string(),
        password: password.to_string(),
        auth_mode: auth_mode.to_string(),
        allow_insecure_tls,
    })?;
    let client = build_client(&creds)?;
    list_entries_with(&creds, &client, "").await?;
    let token = format!(
        "webdav-setup-{}-{}",
        std::process::id(),
        NEXT_SETUP_ID.fetch_add(1, Ordering::Relaxed)
    );
    let mut profiles = SETUP_PROFILES.lock().unwrap();
    profiles.clear();
    profiles.insert(
        token.clone(),
        SetupProfile {
            creds,
            client,
            created_at: Instant::now(),
        },
    );
    Ok(token)
}

fn webdav_transport_error(
    base_url: &str,
    error: impl std::error::Error + Send + Sync + 'static,
) -> anyhow::Error {
    let error = anyhow::Error::new(error);
    let detail = format!("{error:#}");
    let lower = detail.to_ascii_lowercase();
    if base_url.starts_with("https://")
        && (lower.contains("certificate")
            || lower.contains("unknownissuer")
            || lower.contains("unknown issuer")
            || lower.contains("invalid peer certificate"))
    {
        return anyhow::anyhow!(
            "HTTPS 证书不受信任。若这是可信局域网内的自签名 NAS，可返回连接页开启“忽略 HTTPS 证书错误”；否则请为服务器安装受信任证书。详细原因：{detail}"
        );
    }
    if base_url.starts_with("http://")
        && (lower.contains("connection reset")
            || lower.contains("unexpected eof")
            || lower.contains("error sending request"))
    {
        return anyhow::anyhow!(
            "服务器中断了明文 HTTP 连接；当前端口可能只接受 HTTPS。请改用 https:// 地址，自签名证书则开启“忽略 HTTPS 证书错误”。详细原因：{detail}"
        );
    }
    anyhow::anyhow!("WebDAV PROPFIND 失败：{detail}")
}

pub async fn setup_list_entries(token: &str, subdir: &str) -> Result<Vec<RemoteEntry>> {
    let setup = SETUP_PROFILES
        .lock()
        .unwrap()
        .get(token)
        .cloned()
        .context("WebDAV setup session has expired")?;
    if setup.created_at.elapsed() > SETUP_PROFILE_LIFETIME {
        SETUP_PROFILES.lock().unwrap().remove(token);
        anyhow::bail!("WebDAV setup session has expired");
    }
    list_entries_with(&setup.creds, &setup.client, subdir).await
}

pub fn setup_cancel(token: &str) {
    SETUP_PROFILES.lock().unwrap().remove(token);
}

pub fn setup_commit(token: &str) -> Result<()> {
    let setup = SETUP_PROFILES
        .lock()
        .unwrap()
        .remove(token)
        .context("WebDAV setup session has expired")?;
    if setup.created_at.elapsed() > SETUP_PROFILE_LIFETIME {
        anyhow::bail!("WebDAV setup session has expired");
    }
    ensure_configuration_can_change(Some(&setup.creds))?;
    *CREDS.lock().unwrap() = Some(setup.creds.clone());
    *CLIENT.lock().unwrap() = Some((setup.creds, setup.client));
    clear_playable();
    Ok(())
}

/// allprop may report optional fields in a separate 404 propstat. Only
/// successful resource type establishes whether this entry is a directory;
/// failed core type/size properties cannot be treated as a complete snapshot.
fn validate_listing_properties(bytes: &[u8]) -> Result<()> {
    use quick_xml::events::Event;
    let mut reader = quick_xml::Reader::from_reader(bytes);
    let mut in_block = false;
    let mut in_status = false;
    let mut block_type = false;
    let mut block_size = false;
    let mut status = String::new();
    let mut known_type = false;
    loop {
        match reader.read_event()? {
            Event::Start(tag) => match tag.local_name().as_ref() {
                b"response" => known_type = false,
                b"propstat" => {
                    in_block = true;
                    block_type = false;
                    block_size = false;
                    status.clear();
                }
                b"status" if in_block => in_status = true,
                b"resourcetype" if in_block => block_type = true,
                b"getcontentlength" if in_block => block_size = true,
                _ => {}
            },
            Event::Empty(tag) if in_block => match tag.local_name().as_ref() {
                b"resourcetype" => block_type = true,
                b"getcontentlength" => block_size = true,
                _ => {}
            },
            Event::Text(text) if in_status => status.push_str(&text.decode()?),
            Event::End(tag) => match tag.local_name().as_ref() {
                b"status" => in_status = false,
                b"propstat" => {
                    let success = status
                        .split_whitespace()
                        .nth(1)
                        .and_then(|code| code.parse::<u16>().ok())
                        .is_some_and(|code| (200..300).contains(&code));
                    if !success && (block_type || block_size) {
                        anyhow::bail!("WebDAV 核心项目属性读取失败，保留既有索引");
                    }
                    known_type |= success && block_type;
                    in_block = false;
                }
                b"response" if !known_type => {
                    anyhow::bail!("WebDAV 项目缺少成功的资源类型，保留既有索引")
                }
                _ => {}
            },
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(())
}

fn entries_from_responses(
    creds: &WebDavCreds,
    requested: &str,
    responses: Vec<ListResponse>,
) -> Result<Vec<RemoteEntry>> {
    let mut entries = Vec::new();
    for response in responses {
        let Some(relative) = relative_from_href(creds, &response.href)? else {
            continue;
        };
        if relative == requested {
            continue;
        }
        let props = response
            .prop_stat
            .iter()
            .filter(|status| {
                status
                    .status
                    .split_whitespace()
                    .nth(1)
                    .and_then(|code| code.parse::<u16>().ok())
                    .is_some_and(|code| (200..300).contains(&code))
            })
            .map(|status| &status.prop)
            .collect::<Vec<_>>();
        if props.is_empty() {
            anyhow::bail!("WebDAV 目录项目读取失败，保留既有索引：{relative}");
        }
        let name = relative.rsplit('/').next().unwrap_or(&relative).to_string();
        if name.is_empty() {
            continue;
        }
        entries.push(RemoteEntry {
            path: relative,
            name,
            is_directory: props
                .iter()
                .any(|prop| prop.resource_type.collection.is_some()),
            size: props
                .iter()
                .find_map(|prop| prop.content_length)
                .unwrap_or(0),
        });
    }
    entries.sort_by(|a, b| {
        b.is_directory
            .cmp(&a.is_directory)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

pub async fn enumerate(subdir: &str) -> Result<Vec<ScannedFile>> {
    let root = normalize_relative(subdir)?;
    let mut stack = vec![(root.clone(), String::new())];
    let mut visited = HashSet::new();
    let mut files = Vec::new();
    while let Some((directory, relative_parent)) = stack.pop() {
        if crate::scan_control::is_cancelled() {
            anyhow::bail!("扫描已取消");
        }
        if !visited.insert(directory.clone()) {
            continue;
        }
        let entries = tokio::select! {
            result = list_entries(&directory) => result?,
            _ = crate::scan_control::wait_cancelled() => {
                anyhow::bail!("扫描已取消");
            }
        };
        for entry in entries {
            if crate::scan_control::is_cancelled() {
                anyhow::bail!("扫描已取消");
            }
            if visited.len() + files.len() >= MAX_ENUMERATED_ENTRIES {
                anyhow::bail!("WebDAV 目录项目超过安全上限");
            }
            if entry.is_directory {
                let child_parent = if relative_parent.is_empty() {
                    entry.name.clone()
                } else {
                    format!("{relative_parent}/{}", entry.name)
                };
                stack.push((entry.path, child_parent));
            } else if crate::smb::is_video(&entry.name) {
                files.push(ScannedFile {
                    uri: uri_for_relative(&entry.path)?,
                    file_name: entry.name,
                    file_size: entry.size,
                    relative_parent: relative_parent.clone(),
                });
            }
        }
    }
    Ok(files)
}

pub async fn enumerate_source(source_uri: &str) -> Result<Vec<ScannedFile>> {
    let relative = relative_from_uri(source_uri)?;
    enumerate(&relative).await
}

pub async fn list_subtitles(remote_uri: &str) -> Result<Vec<SubtitleCandidate>> {
    let relative = relative_from_uri(remote_uri)?;
    let (directory, video_name) = relative
        .rsplit_once('/')
        .map(|(dir, name)| (dir.to_string(), name.to_string()))
        .unwrap_or_else(|| (String::new(), relative.clone()));
    let mut subtitles = Vec::new();
    for entry in list_entries(&directory).await? {
        if !entry.is_directory && crate::recognize::subtitle_matches_video(&video_name, &entry.name)
        {
            subtitles.push(SubtitleCandidate {
                file_name: entry.name,
                uri: uri_for_relative(&entry.path)?,
            });
        }
    }
    Ok(subtitles)
}

pub async fn read_file_limited(remote_uri: &str, limit: usize) -> Result<Vec<u8>> {
    let relative = relative_from_uri(remote_uri)?;
    let (_, client) = client()?;
    let response = tokio::time::timeout(READ_TIMEOUT, client.get(&encoded_relative(&relative)))
        .await
        .context("WebDAV 字幕读取超时")?
        .context("WebDAV 字幕读取失败")?;
    read_response_limited(response, limit, READ_TIMEOUT).await
}

async fn read_response_limited(
    response: reqwest::Response,
    limit: usize,
    timeout: Duration,
) -> Result<Vec<u8>> {
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        anyhow::bail!("WebDAV 响应超过 {} 字节安全上限", limit);
    }
    tokio::time::timeout(timeout, async move {
        let mut body = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = body.next().await {
            let chunk = chunk.context("WebDAV 响应读取失败")?;
            if bytes.len().saturating_add(chunk.len()) > limit {
                anyhow::bail!("WebDAV 响应超过 {} 字节安全上限", limit);
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(bytes)
    })
    .await
    .context("WebDAV 响应读取超时")?
}

fn normalize_relative(path: &str) -> Result<String> {
    // A percent-decoded href can carry a literal backslash (`%5C`); on Windows
    // Path::join treats it as a separator, so it would escape the cache dir.
    if path.contains('\\') {
        anyhow::bail!("WebDAV 路径不能包含反斜杠");
    }
    let mut clean = Vec::new();
    for segment in path.trim_matches('/').split('/') {
        if segment.is_empty() || segment == "." {
            continue;
        }
        if segment == ".." {
            anyhow::bail!("WebDAV 路径不能离开配置根目录");
        }
        clean.push(segment);
    }
    Ok(clean.join("/"))
}

fn encoded_relative(path: &str) -> String {
    path.split('/')
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            percent_encoding::utf8_percent_encode(segment, percent_encoding::NON_ALPHANUMERIC)
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("/")
}

pub fn uri_for_relative(path: &str) -> Result<String> {
    let creds = creds()?;
    let mut url = Url::parse(&creds.base_url)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| anyhow::anyhow!("WebDAV 基础地址不能包含此路径"))?;
        segments.pop_if_empty();
        for segment in normalize_relative(path)?.split('/') {
            if !segment.is_empty() {
                segments.push(segment);
            }
        }
    }
    Ok(url.to_string())
}

fn relative_from_uri(uri: &str) -> Result<String> {
    let creds = creds()?;
    relative_from_url(&creds, &Url::parse(uri).context("WebDAV 文件地址无效")?)?
        .context("WebDAV 文件不属于当前配置根目录")
}

fn relative_from_href(creds: &WebDavCreds, href: &str) -> Result<Option<String>> {
    let base = Url::parse(&creds.base_url)?;
    let url = Url::parse(href).or_else(|_| base.join(href));
    let Ok(url) = url else {
        return Ok(None);
    };
    relative_from_url(creds, &url)
}

fn relative_from_url(creds: &WebDavCreds, url: &Url) -> Result<Option<String>> {
    let base = Url::parse(&creds.base_url)?;
    if base.scheme() != url.scheme()
        || base.host_str() != url.host_str()
        || base.port_or_known_default() != url.port_or_known_default()
    {
        return Ok(None);
    }
    let Some(suffix) = url.path().strip_prefix(base.path()) else {
        return Ok(None);
    };
    let decoded = percent_decode_str(suffix)
        .decode_utf8()
        .context("WebDAV href 不是有效 UTF-8")?;
    Ok(Some(normalize_relative(&decoded)?))
}

// ---- Loopback range proxy ----

#[derive(Clone)]
struct PlayableFile {
    relative: String,
    cancellation: tokio::sync::watch::Sender<bool>,
}

static PLAYABLE: Lazy<Mutex<HashMap<String, PlayableFile>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static PROXY_PORT: AtomicU16 = AtomicU16::new(0);
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);
static PROXY_START: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

pub async fn register_playable(remote_uri: &str) -> Result<String> {
    let relative = relative_from_uri(remote_uri)?;
    require_range_support(&relative).await?;
    let port = ensure_proxy().await?;
    let token = format!(
        "w{}-{}",
        std::process::id(),
        NEXT_TOKEN.fetch_add(1, Ordering::Relaxed)
    );
    let (cancellation, _) = tokio::sync::watch::channel(false);
    PLAYABLE.lock().unwrap().insert(
        token.clone(),
        PlayableFile {
            relative,
            cancellation,
        },
    );
    Ok(format!("http://127.0.0.1:{port}/{token}"))
}

pub fn unregister_playable(url: &str) {
    if let Some(token) = url.rsplit('/').next() {
        if let Some(playable) = PLAYABLE.lock().unwrap().remove(token) {
            let _ = playable.cancellation.send(true);
        }
    }
}

fn clear_playable() {
    let playables = std::mem::take(&mut *PLAYABLE.lock().unwrap());
    for playable in playables.into_values() {
        let _ = playable.cancellation.send(true);
    }
}

async fn require_range_support(relative: &str) -> Result<u64> {
    let (_, client) = client()?;
    let response = tokio::time::timeout(
        READ_TIMEOUT,
        client
            .start_request(Method::GET, &encoded_relative(relative))
            .await?
            .header(RANGE, "bytes=0-0")
            .send(),
    )
    .await
    .context("WebDAV Range 探测超时")?
    .context("WebDAV Range 探测失败")?;
    if response.status() != StatusCode::PARTIAL_CONTENT {
        anyhow::bail!("WebDAV 服务器不支持 Range 流式读取；该文件只能下载后播放");
    }
    total_from_content_range(response.headers().get(CONTENT_RANGE))
        .context("WebDAV Range 响应缺少有效 Content-Range")
}

/// Read exact ranges without registering the file with the playback proxy.
/// Maintenance traffic must not appear in the player's live/cumulative
/// transfer statistics.
pub(crate) async fn read_exact_ranges(
    remote_uri: &str,
    expected_size: u64,
    ranges: &[(u64, u64)],
    cancellation: &mut tokio::sync::watch::Receiver<bool>,
) -> Result<Vec<Vec<u8>>> {
    let relative = relative_from_uri(remote_uri)?;
    let (_, client) = client()?;
    let encoded = encoded_relative(&relative);
    let mut chunks = Vec::with_capacity(ranges.len());
    for &(offset, length) in ranges {
        if *cancellation.borrow() {
            anyhow::bail!("检查已取消");
        }
        let end = offset
            .checked_add(length)
            .and_then(|value| value.checked_sub(1))
            .context("WebDAV 分块范围溢出")?;
        let request = client
            .start_request(Method::GET, &encoded)
            .await
            .context("建立 WebDAV 分块请求")?
            .header(RANGE, format!("bytes={offset}-{end}"));
        let response = tokio::select! {
            _ = cancellation.changed() => anyhow::bail!("检查已取消"),
            result = tokio::time::timeout(
                READ_TIMEOUT,
                request.send(),
            ) => result.context("WebDAV 分块读取连接超时")??,
        };
        if response.status() != StatusCode::PARTIAL_CONTENT {
            anyhow::bail!(
                "WebDAV 服务器没有按 Range 返回分块（HTTP {}）",
                response.status()
            );
        }
        let (actual_start, actual_end, total) = parse_content_range_exact(
            response
                .headers()
                .get(CONTENT_RANGE)
                .and_then(|value| value.to_str().ok())
                .context("WebDAV Range 响应缺少 Content-Range")?,
        )?;
        if (actual_start, actual_end, total) != (offset, end, expected_size) {
            anyhow::bail!("WebDAV 文件大小或分块范围已变化，请重新扫描");
        }
        let mut body = response.bytes_stream();
        let mut bytes = Vec::with_capacity(length as usize);
        while let Some(next) = tokio::select! {
            _ = cancellation.changed() => anyhow::bail!("检查已取消"),
            result = tokio::time::timeout(READ_TIMEOUT, body.next()) => {
                result.context("WebDAV 分块接收超时")?
            },
        } {
            let chunk = next.context("WebDAV 分块接收失败")?;
            if bytes.len().saturating_add(chunk.len()) > length as usize {
                anyhow::bail!("WebDAV Range 响应超过声明长度");
            }
            bytes.extend_from_slice(&chunk);
        }
        if bytes.len() != length as usize {
            anyhow::bail!("WebDAV Range 响应内容不完整");
        }
        chunks.push(bytes);
    }
    Ok(chunks)
}

fn parse_content_range_exact(value: &str) -> Result<(u64, u64, u64)> {
    let value = value
        .strip_prefix("bytes ")
        .context("WebDAV Content-Range 格式无效")?;
    let (range, total) = value
        .split_once('/')
        .context("WebDAV Content-Range 缺少总大小")?;
    let (start, end) = range
        .split_once('-')
        .context("WebDAV Content-Range 缺少范围")?;
    let start = start
        .parse::<u64>()
        .context("WebDAV Content-Range 起点无效")?;
    let end = end
        .parse::<u64>()
        .context("WebDAV Content-Range 终点无效")?;
    let total = total
        .parse::<u64>()
        .context("WebDAV Content-Range 总大小无效")?;
    if start > end || end >= total {
        anyhow::bail!("WebDAV Content-Range 超出文件范围");
    }
    Ok((start, end, total))
}

async fn ensure_proxy() -> Result<u16> {
    let current = PROXY_PORT.load(Ordering::Acquire);
    if current != 0 {
        return Ok(current);
    }
    let _guard = PROXY_START.lock().await;
    let current = PROXY_PORT.load(Ordering::Acquire);
    if current != 0 {
        return Ok(current);
    }
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .context("启动 WebDAV 回环代理")?;
    let port = listener.local_addr()?.port();
    PROXY_PORT.store(port, Ordering::Release);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let _ = handle_proxy_request(stream).await;
            });
        }
        PROXY_PORT.store(0, Ordering::Release);
    });
    Ok(port)
}

async fn handle_proxy_request(mut stream: TcpStream) -> Result<()> {
    let mut request = Vec::with_capacity(4096);
    let mut chunk = [0u8; 2048];
    while request.len() < 16 * 1024 {
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
            .await
            .context("proxy request timeout")??;
        if read == 0 {
            return Ok(());
        }
        request.extend_from_slice(&chunk[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let request_text = String::from_utf8_lossy(&request);
    let first = request_text.lines().next().unwrap_or_default();
    let mut first_parts = first.split_whitespace();
    let method = first_parts.next().unwrap_or_default();
    let route = first_parts.next().unwrap_or_default();
    if method != "GET" && method != "HEAD" {
        return write_proxy_error(&mut stream, "405 Method Not Allowed", "GET/HEAD only").await;
    }
    let token = route
        .trim_start_matches('/')
        .split('?')
        .next()
        .unwrap_or_default();
    let playable = PLAYABLE.lock().unwrap().get(token).cloned();
    let Some(playable) = playable else {
        return write_proxy_error(&mut stream, "404 Not Found", "expired WebDAV token").await;
    };
    let relative = playable.relative;
    let mut cancellation = playable.cancellation.subscribe();
    if *cancellation.borrow() {
        return Ok(());
    }
    let range = request_text.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("range")
            .then(|| value.trim().to_string())
    });
    let (_, client) = client()?;
    let encoded = encoded_relative(&relative);
    let response_request = if method == "HEAD" {
        client
            .start_request(Method::GET, &encoded)
            .await?
            .header(RANGE, "bytes=0-0")
    } else if let Some(requested_range) = range.as_deref() {
        client
            .start_request(Method::GET, &encoded)
            .await?
            .header(RANGE, requested_range)
    } else {
        client.start_request(Method::GET, &encoded).await?
    };
    let response = tokio::select! {
        _ = cancellation.changed() => return Ok(()),
        response = tokio::time::timeout(READ_TIMEOUT, response_request.send()) => {
            response.context("WebDAV proxy response timeout")??
        }
    };
    let expected_status = if method == "HEAD" || range.is_some() {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    if response.status() != expected_status {
        return write_proxy_error(
            &mut stream,
            "502 Bad Gateway",
            if expected_status == StatusCode::PARTIAL_CONTENT {
                "WebDAV server did not honor byte range"
            } else {
                "WebDAV server did not return a complete response"
            },
        )
        .await;
    }
    let total = if expected_status == StatusCode::PARTIAL_CONTENT {
        let Some(total) = total_from_content_range(response.headers().get(CONTENT_RANGE)) else {
            // Answer before the headers are committed; returning Err here
            // dropped the socket and left the client with an empty reply.
            return write_proxy_error(
                &mut stream,
                "502 Bad Gateway",
                "WebDAV server omitted Content-Range",
            )
            .await;
        };
        total
    } else {
        let Some(total) = response.content_length() else {
            return write_proxy_error(
                &mut stream,
                "502 Bad Gateway",
                "WebDAV server omitted Content-Length",
            )
            .await;
        };
        total
    };
    let content_range = response
        .headers()
        .get(CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();
    let content_length = response.content_length().unwrap_or(total);
    let content_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_else(|| crate::smb::mime_for_path(&relative))
        .to_string();

    if method == "HEAD" {
        let headers = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(headers.as_bytes()).await?;
        return Ok(());
    }
    let status = if range.is_some() {
        "206 Partial Content"
    } else {
        "200 OK"
    };
    let mut headers = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {content_length}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
    );
    if range.is_some() {
        headers.push_str(&format!("Content-Range: {content_range}\r\n"));
    }
    headers.push_str("\r\n");
    stream.write_all(headers.as_bytes()).await?;
    let mut body = response.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = cancellation.changed() => break,
            next = tokio::time::timeout(READ_TIMEOUT, body.next()) => {
                next.context("WebDAV proxy read timeout")?
            }
        };
        let Some(chunk) = next else { break };
        let chunk = chunk?;
        if stream.write_all(&chunk).await.is_err() {
            break;
        }
        BYTES_SERVED.fetch_add(chunk.len() as u64, Ordering::Relaxed);
    }
    Ok(())
}

async fn write_proxy_error(stream: &mut TcpStream, status: &str, detail: &str) -> Result<()> {
    let body = detail.replace(['\r', '\n'], " ");
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).await?;
    Ok(())
}

fn total_from_content_range(value: Option<&reqwest::header::HeaderValue>) -> Option<u64> {
    value?.to_str().ok()?.rsplit_once('/')?.1.parse().ok()
}

// ---- Downloads ----

static DOWNLOAD_SEMAPHORE: Lazy<tokio::sync::Semaphore> =
    Lazy::new(|| tokio::sync::Semaphore::new(1));
static CANCELLED: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));
static ACTIVE_TRANSFERS: AtomicUsize = AtomicUsize::new(0);

struct ActiveTransfer;

impl ActiveTransfer {
    fn begin() -> Self {
        ACTIVE_TRANSFERS.fetch_add(1, Ordering::AcqRel);
        Self
    }
}

impl Drop for ActiveTransfer {
    fn drop(&mut self) {
        ACTIVE_TRANSFERS.fetch_sub(1, Ordering::AcqRel);
    }
}

pub fn reset_download_cancellation(uri: &str) {
    CANCELLED.lock().unwrap().remove(uri);
}

pub fn cancel_download(uri: &str) {
    CANCELLED.lock().unwrap().insert(uri.to_string());
}

pub fn download_was_cancelled(uri: &str) -> bool {
    CANCELLED.lock().unwrap().contains(uri)
}

async fn wait_for_download_cancellation(uri: &str) {
    loop {
        if download_was_cancelled(uri) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

pub fn expected_download_path(remote_uri: &str, dest_dir: &str) -> Option<PathBuf> {
    let name = local_file_name(remote_uri).ok()?;
    Some(Path::new(dest_dir).join(name))
}

pub async fn matching_existing_download(
    remote_uri: &str,
    dest_dir: &str,
) -> Result<Option<(String, u64)>> {
    let Some(path) = expected_download_path(remote_uri, dest_dir) else {
        return Ok(None);
    };
    let local_size = match tokio::fs::metadata(&path).await {
        Ok(metadata) if metadata.is_file() && metadata.len() > 0 => metadata.len(),
        _ => return Ok(None),
    };
    let relative = relative_from_uri(remote_uri)?;
    let remote_size = tokio::select! {
        _ = wait_for_download_cancellation(remote_uri) => anyhow::bail!("下载已取消"),
        result = require_range_support(&relative) => result?,
    };
    Ok((remote_size == local_size).then(|| (path.to_string_lossy().to_string(), local_size)))
}

pub async fn download(
    remote_uri: &str,
    dest_dir: &str,
    mut progress: impl FnMut(u64, u64),
) -> Result<String> {
    let _active = ActiveTransfer::begin();
    let _permit = DOWNLOAD_SEMAPHORE.acquire().await?;
    if download_was_cancelled(remote_uri) {
        anyhow::bail!("下载已取消");
    }
    let final_path = expected_download_path(remote_uri, dest_dir).context("WebDAV 文件名无效")?;
    tokio::fs::create_dir_all(dest_dir).await?;
    download_to_path(remote_uri, &final_path, remote_uri, &mut progress).await?;
    Ok(final_path.to_string_lossy().to_string())
}

/// Stream a WebDAV file directly into an already-open MediaStore descriptor.
pub async fn download_to_file(
    remote_uri: &str,
    mut output: tokio::fs::File,
    mut progress: impl FnMut(u64, u64),
) -> Result<u64> {
    let _active = ActiveTransfer::begin();
    let _permit = DOWNLOAD_SEMAPHORE.acquire().await?;
    if download_was_cancelled(remote_uri) {
        anyhow::bail!("下载已取消");
    }
    let relative = relative_from_uri(remote_uri)?;
    let (_, client) = client()?;
    let encoded = encoded_relative(&relative);
    let response = tokio::select! {
        _ = wait_for_download_cancellation(remote_uri) => anyhow::bail!("下载已取消"),
        result = tokio::time::timeout(READ_TIMEOUT, client.get(&encoded)) => {
            result.context("WebDAV 下载连接超时")??
        }
    };
    let total = response.content_length().unwrap_or(0);
    if total == 0 {
        anyhow::bail!("WebDAV 响应缺少文件大小");
    }
    let mut done = 0u64;
    progress(done, total);
    let mut body = response.bytes_stream();
    loop {
        if download_was_cancelled(remote_uri) {
            anyhow::bail!("下载已取消");
        }
        let next = tokio::select! {
            _ = wait_for_download_cancellation(remote_uri) => anyhow::bail!("下载已取消"),
            next = tokio::time::timeout(READ_TIMEOUT, body.next()) => {
                next.context("WebDAV 下载接收超时")?
            }
        };
        let Some(chunk) = next else { break };
        let chunk = chunk?;
        output
            .write_all(&chunk)
            .await
            .context("write MediaStore file")?;
        done += chunk.len() as u64;
        progress(done, total);
    }
    output.flush().await.context("flush MediaStore file")?;
    if done != total {
        anyhow::bail!("下载不完整（{done}/{total} 字节）");
    }
    Ok(done)
}

async fn download_to_path(
    remote_uri: &str,
    final_path: &Path,
    cancellation_uri: &str,
    progress: &mut impl FnMut(u64, u64),
) -> Result<()> {
    let relative = relative_from_uri(remote_uri)?;
    let (_, client) = client()?;
    let encoded = encoded_relative(&relative);
    let response = tokio::select! {
        _ = wait_for_download_cancellation(cancellation_uri) => anyhow::bail!("下载已取消"),
        result = tokio::time::timeout(READ_TIMEOUT, client.get(&encoded)) => {
            result.context("WebDAV 下载连接超时")??
        }
    };
    let total = response.content_length().unwrap_or(0);
    if total == 0 {
        anyhow::bail!("WebDAV 响应缺少文件大小");
    }
    let part_path = PathBuf::from(format!("{}.part", final_path.to_string_lossy()));
    let _ = tokio::fs::remove_file(&part_path).await;
    let mut output = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&part_path)
        .await?;
    let mut done = 0u64;
    progress(done, total);
    let mut body = response.bytes_stream();
    let result = async {
        loop {
            if download_was_cancelled(cancellation_uri) {
                anyhow::bail!("下载已取消");
            }
            let next = tokio::select! {
                _ = wait_for_download_cancellation(cancellation_uri) => anyhow::bail!("下载已取消"),
                next = tokio::time::timeout(READ_TIMEOUT, body.next()) => {
                    next.context("WebDAV 下载接收超时")?
                }
            };
            let Some(chunk) = next else { break };
            let chunk = chunk?;
            output.write_all(&chunk).await?;
            done += chunk.len() as u64;
            progress(done, total);
        }
        output.flush().await?;
        if done != total {
            anyhow::bail!("下载不完整（{done}/{total} 字节）");
        }
        Ok(())
    }
    .await;
    drop(output);
    if let Err(error) = result {
        let _ = tokio::fs::remove_file(&part_path).await;
        return Err(error);
    }
    if tokio::fs::symlink_metadata(final_path).await.is_ok() {
        tokio::fs::remove_file(final_path).await?;
    }
    tokio::fs::rename(part_path, final_path).await?;
    Ok(())
}

pub async fn download_subtitles(remote_uri: &str, dest_dir: &str) -> Result<Vec<String>> {
    let _active = ActiveTransfer::begin();
    let subtitles = list_subtitles(remote_uri).await?;
    if subtitles.is_empty() {
        return Ok(Vec::new());
    }
    let subtitle_dir = Path::new(dest_dir).join(crate::smb::DOWNLOADED_SUBTITLE_DIR);
    tokio::fs::create_dir_all(&subtitle_dir).await?;
    let mut downloaded = Vec::new();
    for subtitle in subtitles {
        if download_was_cancelled(remote_uri) {
            anyhow::bail!("下载已取消");
        }
        let subtitle_name = local_file_name(&subtitle.uri)?;
        let path = subtitle_dir.join(subtitle_name);
        match download_to_path(&subtitle.uri, &path, remote_uri, &mut |_, _| {}).await {
            Ok(()) => downloaded.push(path.to_string_lossy().to_string()),
            Err(error) => eprintln!(
                "KURAKO could not download WebDAV subtitle {}: {error:#}",
                subtitle.file_name
            ),
        }
    }
    Ok(downloaded)
}

fn file_name_from_uri(remote_uri: &str) -> Result<String> {
    let relative = relative_from_uri(remote_uri)?;
    let name = relative
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .context("WebDAV 文件名为空")?;
    Ok(safe_leaf_name(name)?.to_string())
}

fn local_file_name(remote_uri: &str) -> Result<String> {
    let name = file_name_from_uri(remote_uri)?;
    let url = Url::parse(remote_uri).context("WebDAV 文件地址无效")?;
    let mut parent = url;
    {
        let mut segments = parent
            .path_segments_mut()
            .map_err(|_| anyhow::anyhow!("WebDAV 文件地址没有目录"))?;
        segments.pop_if_empty();
        segments.pop();
    }
    parent.set_query(None);
    parent.set_fragment(None);
    let hash = fnv1a64(parent.as_str().as_bytes());
    let local = format!("W{hash:016x} - {name}");
    if local.len() > 240 {
        anyhow::bail!("WebDAV 文件名过长，无法安全下载");
    }
    Ok(local)
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn safe_leaf_name(name: &str) -> Result<&str> {
    if name.is_empty()
        || matches!(name, "." | "..")
        || name.contains(['/', '\\', ':'])
        || name.chars().any(char::is_control)
        || name.ends_with([' ', '.'])
    {
        anyhow::bail!("WebDAV 返回了不安全的文件名");
    }
    let mut components = Path::new(name).components();
    if !matches!(components.next(), Some(std::path::Component::Normal(_)))
        || components.next().is_some()
    {
        anyhow::bail!("WebDAV 返回了不安全的文件名");
    }
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn propfind_item_errors_reject_partial_deletion_snapshot() {
        let creds = WebDavCreds {
            base_url: "https://example.com/dav/".into(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".into(),
            allow_insecure_tls: false,
        };
        for status in [
            "HTTP/1.1 403 Forbidden",
            "HTTP/1.1 404 Not Found",
            "invalid 2oops",
        ] {
            let xml = format!(
                r#"<multistatus xmlns="DAV:"><response><href>/dav/Anime/01.mkv</href><propstat><prop><resourcetype/><getcontentlength>100</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/dav/Anime/hidden</href><propstat><prop><resourcetype/></prop><status>{status}</status></propstat></response></multistatus>"#
            );
            let parsed: ListMultiStatus = serde_xml_rs::from_str(&xml).unwrap();
            assert!(validate_listing_properties(xml.as_bytes()).is_err());
            let _ = parsed;
        }
        let xml = r#"<multistatus xmlns="DAV:"><response><href>/dav/Anime/01.mkv</href><propstat><prop><resourcetype/><getcontentlength>100</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"#;
        let parsed: ListMultiStatus = serde_xml_rs::from_str(xml).unwrap();
        validate_listing_properties(xml.as_bytes()).unwrap();
        let entries = entries_from_responses(&creds, "Anime", parsed.responses).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].size, 100);
    }

    #[test]
    fn propfind_optional_404_preserves_successful_type_and_size() {
        let xml = r#"<multistatus xmlns="DAV:"><response><href>/dav/Anime/01.mkv</href><propstat><prop><resourcetype/><getcontentlength>100</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat><propstat><prop><getetag/></prop><status>HTTP/1.1 404 Not Found</status></propstat></response></multistatus>"#;
        validate_listing_properties(xml.as_bytes()).unwrap();
        let parsed: ListMultiStatus = serde_xml_rs::from_str(xml).unwrap();
        let creds = WebDavCreds {
            base_url: "https://example.com/dav/".into(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".into(),
            allow_insecure_tls: false,
        };
        let entries = entries_from_responses(&creds, "Anime", parsed.responses).unwrap();
        assert_eq!(entries[0].size, 100);
        let missing_type = xml.replace("<resourcetype/>", "");
        assert!(validate_listing_properties(missing_type.as_bytes()).is_err());
    }

    async fn spawn_range_server(
        body: &'static [u8],
        requests: usize,
    ) -> (String, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            for _ in 0..requests {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let mut chunk = [0u8; 1024];
                loop {
                    let read = stream.read(&mut chunk).await.unwrap();
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&chunk[..read]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                let text = String::from_utf8_lossy(&request);
                let range = text.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("range").then(|| value.trim())
                });
                let response = if let Some(range) = range {
                    let bounds = range.strip_prefix("bytes=").unwrap();
                    let (start, end) = bounds.split_once('-').unwrap();
                    let start: usize = start.parse().unwrap();
                    let end: usize = end.parse().unwrap();
                    let slice = &body[start..=end.min(body.len() - 1)];
                    let headers = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nConnection: close\r\n\r\n",
                        slice.len(),
                        start,
                        start + slice.len() - 1,
                        body.len()
                    );
                    [headers.as_bytes(), slice].concat()
                } else {
                    let headers = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    [headers.as_bytes(), body].concat()
                };
                stream.write_all(&response).await.unwrap();
            }
        });
        (format!("http://{address}/"), task)
    }

    #[test]
    fn rejects_parent_traversal() {
        assert!(normalize_relative("Anime/../Secrets").is_err());
    }

    #[test]
    fn content_range_total_is_parsed() {
        let value = reqwest::header::HeaderValue::from_static("bytes 0-0/12345");
        assert_eq!(total_from_content_range(Some(&value)), Some(12345));
    }

    #[test]
    fn maintenance_range_parser_requires_exact_valid_bounds() {
        assert_eq!(
            parse_content_range_exact("bytes 10-19/100").unwrap(),
            (10, 19, 100)
        );
        assert!(parse_content_range_exact("bytes 20-10/100").is_err());
        assert!(parse_content_range_exact("bytes 90-100/100").is_err());
        assert!(parse_content_range_exact("items 10-19/100").is_err());
    }

    #[test]
    fn href_must_stay_under_configured_root() {
        let creds = validate_creds(WebDavCreds {
            base_url: "https://example.test/dav/anime".to_string(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".to_string(),
            allow_insecure_tls: false,
        })
        .unwrap();
        let valid = relative_from_href(&creds, "/dav/anime/Show%201/")
            .unwrap()
            .unwrap();
        assert_eq!(valid, "Show 1");
        assert!(relative_from_href(&creds, "/dav/private/")
            .unwrap()
            .is_none());
    }

    #[test]
    fn insecure_tls_is_explicit_and_https_only() {
        let https = validate_creds(WebDavCreds {
            base_url: "https://nas.example.test/dav".to_string(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".to_string(),
            allow_insecure_tls: true,
        })
        .unwrap();
        assert!(https.allow_insecure_tls);

        let http = validate_creds(WebDavCreds {
            base_url: "http://nas.example.test/dav".to_string(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".to_string(),
            allow_insecure_tls: true,
        })
        .unwrap();
        assert!(!http.allow_insecure_tls);
    }

    #[test]
    fn transport_errors_explain_certificate_and_protocol_failures() {
        let certificate = webdav_transport_error(
            "https://nas.example.test/",
            std::io::Error::other("invalid peer certificate: UnknownIssuer"),
        );
        assert!(certificate.to_string().contains("HTTPS 证书不受信任"));

        let protocol = webdav_transport_error(
            "http://nas.example.test:8443/",
            std::io::Error::other("connection reset by peer"),
        );
        assert!(protocol.to_string().contains("当前端口可能只接受 HTTPS"));
    }

    #[test]
    fn local_file_name_must_be_one_safe_component() {
        assert_eq!(safe_leaf_name("Episode 01.mkv").unwrap(), "Episode 01.mkv");
        for unsafe_name in [
            "",
            ".",
            "..",
            "../secret",
            r"..\secret",
            r"C:\secret",
            "/absolute",
            "trailing.",
            "trailing ",
            "line\nfeed.srt",
        ] {
            assert!(safe_leaf_name(unsafe_name).is_err(), "{unsafe_name:?}");
        }
    }

    #[tokio::test]
    async fn loopback_proxy_preserves_head_range_and_complete_get() {
        const BODY: &[u8] = b"0123456789";
        let bytes_before = proxy_bytes_served();
        let (base_url, server) = spawn_range_server(BODY, 4).await;
        set_creds(Some(WebDavCreds {
            base_url: base_url.clone(),
            user: String::new(),
            password: String::new(),
            auth_mode: "anonymous".to_string(),
            allow_insecure_tls: false,
        }))
        .unwrap();
        let remote = format!("{base_url}episode.mkv");
        let local = register_playable(&remote).await.unwrap();
        let client = reqwest::Client::new();

        let head = client.head(&local).send().await.unwrap();
        assert_eq!(head.status(), StatusCode::OK);
        assert_eq!(
            head.headers()
                .get(reqwest::header::CONTENT_LENGTH)
                .unwrap()
                .to_str()
                .unwrap(),
            BODY.len().to_string()
        );
        assert_eq!(proxy_bytes_served(), bytes_before);

        let partial = client
            .get(&local)
            .header(RANGE, "bytes=1-3")
            .send()
            .await
            .unwrap();
        assert_eq!(partial.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(partial.bytes().await.unwrap().as_ref(), b"123");
        assert_eq!(proxy_bytes_served(), bytes_before + 3);

        let complete = client.get(&local).send().await.unwrap();
        assert_eq!(complete.status(), StatusCode::OK);
        assert_eq!(complete.bytes().await.unwrap().as_ref(), BODY);
        assert_eq!(proxy_bytes_served(), bytes_before + 3 + BODY.len() as u64);

        unregister_playable(&local);
        set_creds(None).unwrap();
        server.await.unwrap();
    }
}
