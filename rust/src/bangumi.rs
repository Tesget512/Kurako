use crate::models::BangumiSubject;
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

const BASE_OFFICIAL: &str = "https://api.bgm.tv";
/// Public, read-only Bangumi mirror. Account/OAuth traffic always stays official.
pub const BASE_MIRROR: &str = "https://api.bangumi.vip";
pub const IMAGE_MIRROR_HOST: &str = "lain.bangumi.vip";
/// Official OAuth lives on the main site, not the API host.
const OAUTH_OFFICIAL: &str = "https://bgm.tv/oauth";
/// The reverse proxy mirrors the site, so its authorization *page* can be used
/// when the official one is unreachable. Its token endpoint cannot: Anubis
/// answers every server-side POST there with a challenge page, so the code
/// exchange always goes to the official endpoint. The token itself is valid on
/// both hosts, which is why only the page needs a route choice.
const OAUTH_PAGE_MIRROR: &str = "https://bangumi.vip/oauth";

/// Mirror is opt-in and only becomes enabled after an application-side probe.
static MIRROR: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Independent opt-ins. A token obtained either way works on both hosts, so
/// these only decide which host carries each kind of request.
static OAUTH_VIA_MIRROR: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static COLLECTION_VIA_MIRROR: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

pub fn set_mirror(enabled: bool) {
    let guard = MIRROR_VERIFICATION.lock().unwrap();
    let verified = guard
        .as_ref()
        .is_some_and(|v| v.api_verified && v.image_verified);
    MIRROR.store(enabled && verified, std::sync::atomic::Ordering::Relaxed);
}

/// Configure which traffic may use the reverse proxy. Both flags are ignored
/// unless the proxy itself is enabled and verified.
///
/// The login flag only affects the authorization *page*; the code exchange is
/// always official (see `oauth_post`). The collection flag covers the reads and
/// writes, which is the only way an account request reaches the proxy.
pub fn set_route_options(oauth_via_mirror: bool, collection_via_mirror: bool) {
    OAUTH_VIA_MIRROR.store(oauth_via_mirror, std::sync::atomic::Ordering::Relaxed);
    COLLECTION_VIA_MIRROR.store(collection_via_mirror, std::sync::atomic::Ordering::Relaxed);
}

pub(crate) fn mirror_is_enabled() -> bool {
    MIRROR.load(std::sync::atomic::Ordering::Relaxed)
}

/// True only when the proxy is enabled AND the feature opted in.
fn mirror_route(flag: &std::sync::atomic::AtomicBool) -> bool {
    MIRROR.load(std::sync::atomic::Ordering::Relaxed)
        && flag.load(std::sync::atomic::Ordering::Relaxed)
}

fn api_base() -> &'static str {
    if MIRROR.load(std::sync::atomic::Ordering::Relaxed) {
        BASE_MIRROR
    } else {
        BASE_OFFICIAL
    }
}

/// The authorization page the browser opens; the only OAuth URL that may be
/// routed through the reverse proxy.
fn oauth_page_base() -> &'static str {
    if mirror_route(&OAUTH_VIA_MIRROR) {
        OAUTH_PAGE_MIRROR
    } else {
        OAUTH_OFFICIAL
    }
}

/// Collections default to the official API; the per-feature opt-in can route
/// them through the reverse proxy instead.
fn collection_base() -> &'static str {
    if mirror_route(&COLLECTION_VIA_MIRROR) {
        BASE_MIRROR
    } else {
        BASE_OFFICIAL
    }
}
const USER_AGENT: &str = "Kurako/1.0";
const MIRROR_FAILURE: &str = "Bangumi 反向代理验证已失效或请求被拦截，请在设置中重新验证或关闭反向代理回退官方；请确保 WebView 与应用使用相同网络/代理出口（UA/IP 改变会使验证失效）。";

// Deliberately no Debug/Serialize: these are local challenge credentials, not OAuth.
#[derive(Clone)]
struct MirrorVerification {
    generation: u64,
    api_cookie: String,
    image_cookie: String,
    user_agent: String,
    api_verified: bool,
    image_verified: bool,
}
static MIRROR_VERIFICATION: Lazy<Mutex<Option<MirrorVerification>>> =
    Lazy::new(|| Mutex::new(None));
static MIRROR_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn validate_challenge_cookie(cookie: &str) -> Result<()> {
    if cookie.len() > 16384 || cookie.contains(['\r', '\n']) {
        anyhow::bail!("反向代理验证 Cookie 无效，请重新验证。");
    }
    if cookie.is_empty() {
        return Ok(());
    }
    for pair in cookie.split(';') {
        let Some((name, value)) = pair.trim().split_once('=') else {
            anyhow::bail!("反向代理验证 Cookie 无效，请重新验证。");
        };
        if !matches!(
            name,
            "techaro.lol-anubis-auth" | "techaro.lol-anubis-cookie-verification"
        ) || value.is_empty()
            || !value
                .bytes()
                .all(|b| (0x21..=0x7e).contains(&b) && b != b';')
        {
            anyhow::bail!("反向代理验证只允许 Anubis Cookie，不接受账户凭据。");
        }
    }
    Ok(())
}

pub fn configure_mirror_verification(
    api_cookie: String,
    image_cookie: String,
    user_agent: String,
) -> Result<()> {
    validate_challenge_cookie(&api_cookie)?;
    validate_challenge_cookie(&image_cookie)?;
    if user_agent.trim().is_empty()
        || user_agent.len() > 2048
        || reqwest::header::HeaderValue::from_str(&user_agent).is_err()
    {
        anyhow::bail!("无法读取有效 WebView User-Agent，请关闭反向代理回退官方。");
    }
    let mut guard = MIRROR_VERIFICATION.lock().unwrap();
    MIRROR.store(false, std::sync::atomic::Ordering::Relaxed);
    let api_verified = guard.as_ref().is_some_and(|v| {
        v.api_cookie == api_cookie && v.user_agent == user_agent && v.api_verified
    });
    *guard = Some(MirrorVerification {
        generation: MIRROR_GENERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        api_cookie,
        image_cookie,
        user_agent,
        api_verified,
        image_verified: false,
    });
    Ok(())
}

pub fn clear_mirror_verification() {
    let mut guard = MIRROR_VERIFICATION.lock().unwrap();
    MIRROR.store(false, std::sync::atomic::Ordering::Relaxed);
    *guard = None;
}

fn proof_headers(
    req: reqwest::RequestBuilder,
    proof: &MirrorVerification,
    image: bool,
) -> reqwest::RequestBuilder {
    let cookie = if image {
        &proof.image_cookie
    } else {
        &proof.api_cookie
    };
    let req = req.header(reqwest::header::USER_AGENT, &proof.user_agent);
    if cookie.is_empty() {
        req
    } else {
        req.header(reqwest::header::COOKIE, cookie)
    }
}

fn mirror_headers(req: reqwest::RequestBuilder, image: bool) -> reqwest::RequestBuilder {
    let guard = MIRROR_VERIFICATION.lock().unwrap();
    if let Some(v) = guard.as_ref() {
        let cookie = if image {
            &v.image_cookie
        } else {
            &v.api_cookie
        };
        let req = req.header(reqwest::header::USER_AGENT, &v.user_agent);
        if cookie.is_empty() {
            req
        } else {
            req.header(reqwest::header::COOKIE, cookie)
        }
    } else {
        req
    }
}

/// Force the mirror regardless of the preference, without OAuth credentials.
/// Returns a validated image probe URL from this actual subject response.
pub async fn probe_mirror() -> Result<String> {
    let proof = MIRROR_VERIFICATION
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow::anyhow!(MIRROR_FAILURE))?;
    let c = client()?;
    let mut resp = send_with_backoff(
        || proof_headers(c.get(format!("{BASE_MIRROR}/v0/subjects/1")), &proof, false),
        "bangumi mirror probe",
    )
    .await?;
    if !resp.status().is_success() {
        anyhow::bail!(MIRROR_FAILURE);
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| anyhow::anyhow!(MIRROR_FAILURE))?
    {
        if body.len().saturating_add(chunk.len()) > 1024 * 1024 {
            anyhow::bail!("反向代理 API 响应超过验证大小限制，未开启反向代理。");
        }
        body.extend_from_slice(&chunk);
    }
    let value: serde_json::Value =
        serde_json::from_slice(&body).map_err(|_| anyhow::anyhow!(MIRROR_FAILURE))?;
    if value["id"].as_i64() != Some(1) {
        anyhow::bail!(MIRROR_FAILURE);
    }
    let image = ["large", "common", "medium", "small"]
        .iter()
        .find_map(|key| value["images"][*key].as_str())
        .ok_or_else(|| {
            anyhow::anyhow!("反向代理 API 返回有效条目但无可验证封面，未开启反向代理。")
        })?;
    let mut url = reqwest::Url::parse(image).context("反向代理封面地址无效")?;
    if !matches!(
        url.host_str(),
        Some("lain.bgm.tv" | "bgmimg.anibt.net" | "lain.bangumi.vip")
    ) || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        anyhow::bail!("反向代理返回未知封面域名，未开启反向代理。");
    }
    url.set_scheme("https")
        .map_err(|_| anyhow::anyhow!("反向代理封面协议无效"))?;
    url.set_host(Some(IMAGE_MIRROR_HOST))?;
    let mut guard = MIRROR_VERIFICATION.lock().unwrap();
    let v = guard
        .as_mut()
        .filter(|v| v.generation == proof.generation)
        .ok_or_else(|| anyhow::anyhow!("反向代理验证配置已改变，请重新开始验证。"))?;
    v.api_verified = true;
    Ok(url.to_string())
}

pub async fn probe_mirror_image(image_url: String) -> Result<()> {
    let proof = MIRROR_VERIFICATION
        .lock()
        .unwrap()
        .clone()
        .filter(|v| v.api_verified)
        .ok_or_else(|| anyhow::anyhow!(MIRROR_FAILURE))?;
    let url = reqwest::Url::parse(&image_url).context("反向代理封面地址无效")?;
    if url.scheme() != "https"
        || url.host_str() != Some(IMAGE_MIRROR_HOST)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        anyhow::bail!("反向代理封面验证仅允许已确认的域名。");
    }
    let c = client()?;
    let mut resp = send_with_backoff(
        || proof_headers(c.get(url.clone()), &proof, true),
        "bangumi mirror image probe",
    )
    .await?;
    let is_image = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.starts_with("image/"));
    if !resp.status().is_success() || !is_image {
        anyhow::bail!(MIRROR_FAILURE);
    }
    // Limit the actual decompressed body, not only Content-Length.
    let mut bytes = 0usize;
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| anyhow::anyhow!(MIRROR_FAILURE))?
    {
        bytes = bytes.saturating_add(chunk.len());
        if bytes > 8 * 1024 * 1024 {
            anyhow::bail!("反向代理封面超过验证大小限制，未开启反向代理。");
        }
    }
    if bytes == 0 {
        anyhow::bail!(MIRROR_FAILURE);
    }
    let mut guard = MIRROR_VERIFICATION.lock().unwrap();
    let v = guard
        .as_mut()
        .filter(|v| v.generation == proof.generation && v.api_verified)
        .ok_or_else(|| anyhow::anyhow!("反向代理验证配置已改变，请重新开始验证。"))?;
    v.image_verified = true;
    Ok(())
}

// Bangumi OAuth application credentials. The real values live in the
// git-ignored `secrets.rs` (copy `secrets.rs.example` → `secrets.rs`). A desktop
// app is a "public client" — the secret can't be truly confidential in a
// distributed binary — but keeping it out of the public repo avoids scraping
// and lets forks use their own app.
#[path = "secrets.rs"]
mod secrets;
pub use secrets::{OAUTH_CLIENT_ID, OAUTH_CLIENT_SECRET};
/// Must match the "回调地址" registered on the developer console.
/// The single callback URL registered for the KURAKO OAuth application.
///
/// A loopback HTTP callback works on an active desktop process but is not
/// reliable on iOS/iPadOS: launching the browser suspends the app that owns the
/// temporary local server.  A custom scheme lets the OS hand the completed
/// authorization straight back to the active authentication session instead.
pub const OAUTH_REDIRECT_URI: &str = "kurako://oauth/callback";

static TOKEN: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
/// Cached username of the logged-in user. The collection *read* endpoints
/// require a real `:username` in the path — the `-` placeholder only works for
/// *writes*. Fetched lazily from `/v0/me` and cleared when the token changes.
static USERNAME: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

pub fn set_token(token: Option<String>) {
    let t = token.filter(|s| !s.trim().is_empty());
    *TOKEN.lock().unwrap() = t;
    // Invalidate any cached username; it belongs to the previous token.
    *USERNAME.lock().unwrap() = None;
}

/// The logged-in user's `username` (needed for collection read endpoints),
/// fetched from `/v0/me` and cached for the lifetime of the token.
async fn current_username() -> Result<String> {
    if let Some(u) = USERNAME.lock().unwrap().clone() {
        return Ok(u);
    }
    let client = client()?;
    let resp = send_with_backoff(
        || collection_auth(client.get(format!("{}/v0/me", collection_base()))),
        "bangumi me",
    )
    .await?;
    if !resp.status().is_success() {
        anyhow::bail!("bangumi /v0/me failed: {}", resp.status());
    }
    #[derive(Deserialize)]
    struct Me {
        username: String,
    }
    let me: Me = resp.json().await.context("parse /v0/me")?;
    *USERNAME.lock().unwrap() = Some(me.username.clone());
    Ok(me.username)
}

/// Process-wide HTTP client, built once and reused. A `reqwest::Client` owns a
/// connection pool with keep-alive, so reusing it lets the many per-scan
/// requests (each anime does several sequential search/detail calls) share warm
/// TCP+TLS connections instead of paying a fresh handshake every time — the real
/// reason auto-match felt slow despite matching animes concurrently. Cloning a
/// Client is cheap (it's `Arc` inside). Cleared by `reset_http_client` when the
/// proxy environment may have changed.
static HTTP_CLIENT: Lazy<Mutex<Option<reqwest::Client>>> = Lazy::new(|| Mutex::new(None));

/// Drop the cached client so the next `client()` rebuilds it (e.g. after the
/// system proxy changes). Cheap; the pool is re-established lazily.
pub fn reset_http_client() {
    *HTTP_CLIENT.lock().unwrap() = None;
}

fn client() -> Result<reqwest::Client> {
    let mut guard = HTTP_CLIENT.lock().unwrap();
    if let Some(c) = guard.as_ref() {
        return Ok(c.clone());
    }

    let mut builder = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        // Mirror challenge credentials never follow a Location. Preserve the
        // existing bounded redirect behavior for official API/OAuth traffic.
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let mirror = attempt
                .previous()
                .iter()
                .any(|url| matches!(url.host_str(), Some("api.bangumi.vip" | "lain.bangumi.vip")));
            if mirror || attempt.previous().len() >= 10 {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30))
        // Keep idle connections warm across the burst of scan requests.
        .pool_idle_timeout(std::time::Duration::from_secs(90));

    // Bangumi (api.bgm.tv / lain.bgm.tv) is frequently DNS-poisoned in mainland
    // China, so a direct connection times out. Auto-detect the system HTTP proxy
    // (e.g. clash/v2rayN at 127.0.0.1:7890) and route requests through it.
    if let Some(proxy_url) = detect_system_proxy() {
        if let Ok(p) = reqwest::Proxy::all(&proxy_url) {
            builder = builder.proxy(p);
        }
    }

    let built = builder.build().context("build http client")?;
    *guard = Some(built.clone());
    Ok(built)
}

/// Detect a system HTTP proxy: environment variables first, then the native
/// desktop setting used by the current platform.
pub fn detect_system_proxy() -> Option<String> {
    for var in [
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
    ] {
        if let Ok(val) = std::env::var(var) {
            let v = val.trim();
            if !v.is_empty() {
                return Some(normalize_proxy(v));
            }
        }
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        if let Some(p) = crate::apple_proxy::system_proxy() {
            return Some(p);
        }
    }
    #[cfg(windows)]
    {
        if let Some(p) = read_windows_proxy() {
            return Some(p);
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(p) = read_linux_desktop_proxy() {
            return Some(p);
        }
    }
    None
}

fn normalize_proxy(v: &str) -> String {
    let v = v.trim();
    if v.contains("://") {
        v.to_string()
    } else {
        format!("http://{}", v)
    }
}

#[cfg(target_os = "linux")]
fn read_linux_desktop_proxy() -> Option<String> {
    let mode = gsettings_value(&["get", "org.gnome.system.proxy", "mode"])?;
    let https = gsettings_proxy_endpoint("org.gnome.system.proxy.https");
    let http = gsettings_proxy_endpoint("org.gnome.system.proxy.http");
    desktop_proxy_from_values(&mode, https.as_ref(), http.as_ref())
}

#[cfg(target_os = "linux")]
fn gsettings_proxy_endpoint(schema: &str) -> Option<(String, u16)> {
    let host = gsettings_value(&["get", schema, "host"])?;
    let host = host.trim_matches('\'').trim().to_string();
    let port = gsettings_value(&["get", schema, "port"])?;
    let port = port.trim().parse::<u16>().ok()?;
    Some((host, port))
}

#[cfg(any(target_os = "linux", test))]
fn desktop_proxy_from_values(
    mode: &str,
    https: Option<&(String, u16)>,
    http: Option<&(String, u16)>,
) -> Option<String> {
    if mode.trim_matches('\'') != "manual" {
        return None;
    }

    // HTTPS URLs use an HTTP CONNECT proxy in the standard GNOME settings.
    // Prefer the HTTPS entry, then fall back to the HTTP entry when desktops
    // are configured to use the same proxy for all protocols.
    for (host, port) in [https, http].into_iter().flatten() {
        let host = host.trim();
        if host.is_empty() || *port == 0 {
            continue;
        }
        let host = if host.contains(':') && !host.starts_with('[') {
            format!("[{host}]")
        } else {
            host.to_string()
        };
        return Some(format!("http://{host}:{port}"));
    }
    None
}

#[cfg(target_os = "linux")]
fn gsettings_value(args: &[&str]) -> Option<String> {
    use std::process::Command;

    let output = Command::new("gsettings").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(windows)]
fn read_windows_proxy() -> Option<String> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu
        .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Internet Settings")
        .ok()?;
    let enabled: u32 = key.get_value("ProxyEnable").unwrap_or(0);
    if enabled == 0 {
        return None;
    }
    let server: String = key.get_value("ProxyServer").ok()?;
    let server = server.trim();
    if server.is_empty() {
        return None;
    }
    // "127.0.0.1:7890" (simple) or "http=host:port;https=host:port;socks=..."
    if !server.contains('=') {
        return Some(normalize_proxy(server));
    }
    // Prefer https entry, then http.
    let mut http_val: Option<String> = None;
    for part in server.split(';') {
        let part = part.trim();
        if let Some((scheme, addr)) = part.split_once('=') {
            let addr = addr.trim();
            if addr.is_empty() {
                continue;
            }
            match scheme.trim().to_ascii_lowercase().as_str() {
                "https" => return Some(normalize_proxy(addr)),
                "http" => http_val = Some(normalize_proxy(addr)),
                _ => {}
            }
        }
    }
    http_val
}

fn auth(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    // Inspect the actual URL, rather than the mutable preference, so concurrent
    // toggles cannot leak a bearer to an already-created mirror request.
    let host = req
        .try_clone()
        .and_then(|r| r.build().ok())
        .and_then(|r| r.url().host_str().map(str::to_owned));
    if host.as_deref() == Some("api.bangumi.vip") {
        return mirror_headers(req, false);
    }
    if host.as_deref() != Some("api.bgm.tv") {
        return req;
    }
    let tok = TOKEN.lock().unwrap().clone();
    match tok {
        Some(t) => req.bearer_auth(t),
        None => req,
    }
}

/// Auth for the collection endpoints, which follow their own route choice.
///
/// `auth()` keeps the bearer on the official host because public search/subject
/// traffic can go through the proxy without credentials. Collections are the
/// one case where the user asked the proxy to carry account requests, so the
/// bearer follows the route they picked — and only that one host receives it.
fn collection_auth(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    // Decide from the actual URL so a concurrent toggle cannot send the bearer
    // to a host the request was not built for.
    let host = req
        .try_clone()
        .and_then(|r| r.build().ok())
        .and_then(|r| r.url().host_str().map(str::to_owned));
    let req = match host.as_deref() {
        Some("api.bangumi.vip") => mirror_headers(req, false),
        Some("api.bgm.tv") => req,
        // Never attach account credentials to any other host.
        _ => return req,
    };
    let tok = TOKEN.lock().unwrap().clone();
    match tok {
        Some(t) => req.bearer_auth(t),
        None => req,
    }
}

// ---- Bangumi API response shapes ----

#[derive(Deserialize)]
struct SearchResponse {
    #[serde(default)]
    data: Vec<RawSubject>,
}

#[derive(Deserialize)]
struct RawSubject {
    id: i64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    name_cn: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    date: Option<String>,
    #[serde(default)]
    eps: Option<i64>,
    #[serde(default)]
    images: Option<Images>,
    #[serde(default)]
    rating: Option<RawRating>,
    #[serde(default)]
    tags: Option<Vec<RawTag>>,
}

#[derive(Deserialize)]
struct RawRating {
    #[serde(default)]
    score: Option<f64>,
    #[serde(default)]
    total: Option<i64>,
    #[serde(default)]
    rank: Option<i64>,
    /// Vote histogram keyed "1".."10".
    #[serde(default)]
    count: Option<std::collections::HashMap<String, i64>>,
}

impl RawRating {
    /// Histogram as a fixed "n1,n2,...,n10" string (score 1 → 10), or None if
    /// the API sent no votes.
    fn counts_csv(&self) -> Option<String> {
        let map = self.count.as_ref()?;
        let counts: Vec<i64> = (1..=10)
            .map(|i| *map.get(&i.to_string()).unwrap_or(&0))
            .collect();
        if counts.iter().all(|c| *c == 0) {
            return None;
        }
        Some(
            counts
                .iter()
                .map(|c| c.to_string())
                .collect::<Vec<_>>()
                .join(","),
        )
    }
}

#[derive(Deserialize, Serialize)]
struct RawTag {
    #[serde(default)]
    name: String,
    #[serde(default)]
    count: i64,
}

#[derive(Deserialize)]
struct Images {
    #[serde(default)]
    large: Option<String>,
    #[serde(default)]
    common: Option<String>,
    #[serde(default)]
    medium: Option<String>,
}

impl Images {
    fn best(&self) -> Option<String> {
        self.large
            .clone()
            .or_else(|| self.common.clone())
            .or_else(|| self.medium.clone())
    }
}

impl From<RawSubject> for BangumiSubject {
    fn from(r: RawSubject) -> Self {
        let tags = r
            .tags
            .unwrap_or_default()
            .into_iter()
            .filter(|tag| !tag.name.is_empty())
            .take(10)
            .collect::<Vec<_>>();
        let tag_counts = (!tags.is_empty())
            .then(|| serde_json::to_string(&tags).ok())
            .flatten();
        BangumiSubject {
            id: r.id,
            name: r.name,
            name_cn: r.name_cn,
            summary: r.summary,
            cover_url: r.images.and_then(|i| i.best()),
            air_date: r.date,
            eps: r.eps,
            rating: r.rating.as_ref().and_then(|x| x.score).filter(|s| *s > 0.0),
            rating_total: r.rating.as_ref().and_then(|x| x.total).filter(|t| *t > 0),
            rating_rank: r.rating.as_ref().and_then(|x| x.rank).filter(|k| *k > 0),
            rating_counts: r.rating.as_ref().and_then(|x| x.counts_csv()),
            tags: tags.into_iter().map(|tag| tag.name).collect(),
            tag_counts,
        }
    }
}

/// Broadcast weekday derived from an air date "YYYY-MM-DD": 1=Mon .. 7=Sun.
pub fn weekday_of(date: &str) -> Option<i64> {
    let mut it = date.split('-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Zeller's congruence (Gregorian), mapped to ISO weekday.
    let (m2, y2) = if m < 3 { (m + 12, y - 1) } else { (m, y) };
    let k = y2 % 100;
    let j = y2 / 100;
    let h = (d + 13 * (m2 + 1) / 5 + k + k / 4 + j / 4 + 5 * j) % 7; // 0=Sat
    Some(((h + 5) % 7) + 1)
}

/// Send a request, retrying on 429 (Bangumi rate-limits aggressively during a
/// batch match run). Returns the first non-429 response.
async fn send_with_backoff(
    mk: impl Fn() -> reqwest::RequestBuilder,
    what: &str,
) -> Result<reqwest::Response> {
    for attempt in 0..4 {
        let builder = mk();
        let mirror_request = builder
            .try_clone()
            .and_then(|r| r.build().ok())
            .is_some_and(|r| {
                r.url()
                    .host_str()
                    .is_some_and(|h| h == "api.bangumi.vip" || h == IMAGE_MIRROR_HOST)
            });
        let resp = builder.send().await.map_err(|e| {
            if mirror_request {
                anyhow::anyhow!(MIRROR_FAILURE)
            } else {
                anyhow::Error::new(e).context(format!("{what} request"))
            }
        })?;
        let mirror = resp
            .url()
            .host_str()
            .is_some_and(|host| host == "api.bangumi.vip" || host == IMAGE_MIRROR_HOST);
        let html = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.to_ascii_lowercase().contains("text/html"));
        if mirror && (resp.status().as_u16() == 403 || html) {
            anyhow::bail!(MIRROR_FAILURE);
        }
        if resp.status().as_u16() != 429 {
            return Ok(resp);
        }
        tokio::time::sleep(std::time::Duration::from_millis(900 * (attempt + 1))).await;
    }
    anyhow::bail!("{what}: rate limited (429) after retries");
}

/// Search anime subjects (type=2) by keyword, sorted by relevance.
pub async fn search(keyword: &str, limit: u32) -> Result<Vec<BangumiSubject>> {
    let url = format!("{}/v0/search/subjects?limit={limit}", api_base());
    let body = serde_json::json!({
        "keyword": keyword,
        "sort": "match",
        "filter": { "type": [2] }
    });
    let client = client()?;
    let resp = send_with_backoff(|| auth(client.post(&url).json(&body)), "bangumi search").await?;
    if !resp.status().is_success() {
        anyhow::bail!("bangumi search failed: {}", resp.status());
    }
    let parsed: SearchResponse = resp.json().await.context("parse bangumi search")?;
    Ok(parsed.data.into_iter().map(Into::into).collect())
}

// ---- Legacy search API (GET /search/subject/{kw}) ----
// The v0 search endpoint returns empty for many CJK keywords (especially
// partial or traditional-Chinese titles) where the legacy endpoint still finds
// them, so we fall back to it per keyword.

#[derive(Deserialize)]
struct LegacySearchResponse {
    #[serde(default)]
    list: Option<Vec<LegacySubject>>,
}

#[derive(Deserialize)]
struct LegacySubject {
    id: i64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    name_cn: String,
    #[serde(default)]
    images: Option<Images>,
}

pub async fn search_legacy(keyword: &str, limit: u32) -> Result<Vec<BangumiSubject>> {
    let encoded = urlencode(keyword);
    let url = format!(
        "{}/search/subject/{encoded}?type=2&max_results={limit}&responseGroup=small",
        api_base()
    );
    let client = client()?;
    let resp = send_with_backoff(|| auth(client.get(&url)), "bangumi legacy search").await?;
    if !resp.status().is_success() {
        anyhow::bail!("bangumi legacy search failed: {}", resp.status());
    }
    // On no results this endpoint can return junk/absent fields; be lenient.
    let parsed: LegacySearchResponse = match resp.json().await {
        Ok(p) => p,
        Err(_) => return Ok(Vec::new()),
    };
    Ok(parsed
        .list
        .unwrap_or_default()
        .into_iter()
        .map(|s| BangumiSubject {
            id: s.id,
            name: s.name,
            name_cn: s.name_cn,
            summary: String::new(),
            cover_url: s.images.and_then(|i| i.best()),
            air_date: None,
            eps: None,
            rating: None,
            rating_total: None,
            rating_rank: None,
            rating_counts: None,
            tags: Vec::new(),
            tag_counts: None,
        })
        .collect())
}

fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// Generate progressively looser keyword variants from a raw title, so a title
/// like "Hina Logi from Luck & Logic" also tries "Hina Logi from Luck Logic",
/// "Hina Logi", "Luck Logic", etc. Ordered most-specific first, de-duplicated.
fn keyword_variants(title: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let push = |s: String, out: &mut Vec<String>| {
        let s = s.trim().to_string();
        if s.len() >= 2 && !out.iter().any(|e| e.eq_ignore_ascii_case(&s)) {
            out.push(s);
        }
    };

    push(title.to_string(), &mut out);

    // Bangumi is simplified-Chinese native: for traditional-Chinese filenames
    // the simplified full title is the single best keyword — try it right
    // after the original, not last.
    let simp_full = simplet2s::convert(title);
    push(simp_full, &mut out);

    // Drop punctuation (& , : ~ -) -> spaces.
    let depunct: String = title
        .chars()
        .map(|c| {
            if "&,:~-_!！？?・/".contains(c) {
                ' '
            } else {
                c
            }
        })
        .collect();
    let depunct = depunct.split_whitespace().collect::<Vec<_>>().join(" ");
    push(depunct.clone(), &mut out);

    // Split on connective words ("from", "the", "no", "wa", "to") and keep the
    // longer halves as separate keywords.
    let lower = depunct.to_lowercase();
    for sep in [" from ", " the ", " feat ", " x "] {
        if let Some(idx) = lower.find(sep) {
            let (a, b) = depunct.split_at(idx);
            let b = &b[sep.len()..];
            push(a.to_string(), &mut out);
            push(b.to_string(), &mut out);
        }
    }

    // First 1-3 words (helps when a subtitle is appended).
    let words: Vec<&str> = depunct.split_whitespace().collect();
    if words.len() > 3 {
        push(words[..3].join(" "), &mut out);
    }
    if words.len() > 2 {
        push(words[..2].join(" "), &mut out);
    }
    // Last two words (often the distinctive part, e.g. "Luck Logic", "U149").
    if words.len() >= 2 {
        push(words[words.len() - 2..].join(" "), &mut out);
    }
    if let Some(last) = words.last() {
        if last.len() >= 3 {
            push(last.to_string(), &mut out);
        }
    }

    // Mixed CJK+Latin titles ("我们不可能成为恋人 ... Watanare Next Sunshine"):
    // also try the CJK-only and Latin-only portions on their own.
    let is_cjk_word = |w: &&str| w.chars().any(|c| (c as u32) > 0x2E7F);
    let cjk: Vec<&str> = words.iter().filter(|w| is_cjk_word(w)).copied().collect();
    let latin: Vec<&str> = words.iter().filter(|w| !is_cjk_word(w)).copied().collect();
    if !cjk.is_empty() && !latin.is_empty() {
        push(cjk.join(" "), &mut out);
        push(latin.join(" "), &mut out);
    }

    // Filenames from Taiwan/HK groups use traditional Chinese while Bangumi's
    // name_cn is simplified — add simplified versions of every variant.
    for i in 0..out.len() {
        let simp = simplet2s::convert(&out[i]);
        if simp != out[i] {
            push(simp, &mut out);
        }
    }

    out
}

/// Find the best Bangumi match for a raw parsed title.
///
/// Strategy (calibrated against real library failures): the API's own ranking
/// for a FULL-title query is trustworthy — for romaji titles v0 almost always
/// puts the right show in the top hits even when our text similarity to the
/// JP/CN names is zero. Truncated keyword variants ("Riddle", "Another World",
/// "Witches") exist only to rescue titles the full query can't find, and their
/// hits must pass a hard evidence gate, otherwise fragments match unrelated
/// shows. Returns None below a confidence floor — unmatched beats wrong.
pub async fn best_match(title: &str) -> Result<Option<BangumiSubject>> {
    let variants = keyword_variants(title);
    let norm_title = normalize_for_match(title);
    let t_len = norm_title.chars().count().max(1);

    let mut best: Option<(f64, BangumiSubject)> = None;
    let mut seen_ids: std::collections::HashSet<i64> = std::collections::HashSet::new();

    for kw in variants.iter() {
        let coverage = (normalize_for_match(kw).chars().count() as f64 / t_len as f64).min(1.0);
        // v0 search first. IMPORTANT: only fall back to the legacy fuzzy
        // endpoint when v0 *successfully* returned nothing — a transient v0
        // error (rate limit) must NOT reroute to the much looser legacy
        // matcher at full trust, that's how "Bocchi the Rock!" once matched a
        // GoBots movie. Retry the error once instead.
        let mut hits = Vec::new();
        let mut v0_confirmed_empty = false;
        let mut last_v0_error = None;
        for attempt in 0..2 {
            match search(kw, 5).await {
                Ok(h) if h.is_empty() => {
                    v0_confirmed_empty = true;
                    break;
                }
                Ok(h) => {
                    hits = h;
                    break;
                }
                Err(error) if attempt == 0 => {
                    last_v0_error = Some(error);
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                Err(error) => last_v0_error = Some(error),
            }
        }
        // Trying more keyword variants cannot repair a dead API connection.
        // Propagate the transport failure so the scan-level circuit breaker can
        // stop the remaining library after three failed titles. `Ok(None)` is
        // reserved for requests which actually reached Bangumi but found no
        // sufficiently reliable match.
        if hits.is_empty() && !v0_confirmed_empty {
            return Err(last_v0_error
                .unwrap_or_else(|| anyhow::anyhow!("bangumi search failed without a response")));
        }
        let mut legacy = false;
        if hits.is_empty() && v0_confirmed_empty {
            hits = search_legacy(kw, 5).await.unwrap_or_default();
            legacy = true;
        }
        // Legacy fuzzy matching is decent for CJK keywords (v0's blind spot)
        // and for abbreviation lookups, but noticeably looser — trust its
        // top hit a bit less, latin keywords least.
        let full_base = if !legacy {
            0.55
        } else if kw.chars().any(|c| (c as u32) > 0x2E7F) {
            0.50
        } else {
            0.42
        };
        for (hi, cand) in hits.into_iter().enumerate() {
            if !seen_ids.insert(cand.id) {
                continue;
            }
            // An exact normalized-title match is unbeatable — take it and stop.
            let exact = normalize_for_match(&cand.name) == norm_title
                || normalize_for_match(&cand.name_cn) == norm_title;
            let score = score_candidate(&norm_title, title, &cand, coverage, full_base, hi);
            let better = match &best {
                Some((bs, _)) => score > *bs,
                None => true,
            };
            if better {
                best = Some((score, cand));
            }
            if exact {
                return Ok(best.map(|(_, c)| c));
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }

    // Below the floor, report no match instead of a guess.
    Ok(best.filter(|(s, _)| *s >= 0.38).map(|(_, c)| c))
}

/// Normalize a string for fuzzy title comparison: fold traditional Chinese to
/// simplified (filenames from TW/HK groups vs Bangumi's simplified name_cn),
/// lowercase, keep only alphanumeric.
fn normalize_for_match(s: &str) -> String {
    simplet2s::convert(s)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

/// Score a candidate against the parsed title.
///
/// `coverage` is how much of the title the search keyword covered (1.0 = the
/// full title was queried). Full-title hits get a rank-based trust prior;
/// truncated-keyword hits get NO prior and must clear a hard text-evidence
/// gate instead, because a fragment like "Riddle" or "Another World" happily
/// returns real-but-unrelated shows.
fn score_candidate(
    norm_title: &str,
    raw_title: &str,
    cand: &BangumiSubject,
    coverage: f64,
    full_base: f64,
    hit_idx: usize,
) -> f64 {
    let n_name = normalize_for_match(&cand.name);
    let n_cn = normalize_for_match(&cand.name_cn);

    // An exact normalized-title match trumps everything, regardless of which
    // keyword variant or API rank surfaced it — the sequel "…再次闪耀" must
    // never outrank the identically-titled base show.
    if n_name == *norm_title || n_cn == *norm_title {
        return 2.0 - 0.02 * hit_idx as f64;
    }

    // Raw text overlap, before any bonuses — this is what the truncated-variant
    // evidence gate checks.
    let raw_overlap = overlap(norm_title, &n_name).max(overlap(norm_title, &n_cn));
    let mut sim = raw_overlap;

    // Distinctive shared token bonus: parsed titles are romaji while Bangumi
    // names are JP/CN, so bigram overlap is weak — but a shared Latin/digit
    // token like "u149"/"086" is a very strong signal. Extract tokens from the
    // raw (separator-preserving) title so "u149" stays whole.
    let name_blob = format!("{}{}", n_name, n_cn);
    let mut token_bonus: f64 = 0.0;
    let mut shared_digit_token = false;
    for t in latin_tokens(raw_title) {
        let t = t.to_lowercase();
        // ignore generic short words
        if t.len() < 3 || GENERIC_TOKENS.contains(&t.as_str()) {
            continue;
        }
        // digit-bearing tokens (u149, 086, 100) are near-unique identifiers:
        // shared -> strong bonus; missing from candidate -> strong penalty
        // (separates a show from its spin-offs/specials).
        let has_digit = t.chars().any(|c| c.is_ascii_digit());
        if name_blob.contains(&t) {
            token_bonus += if has_digit { 0.6 } else { 0.35 };
            shared_digit_token |= has_digit;
        } else if has_digit {
            token_bonus -= 0.6;
        }
    }
    sim += token_bonus.clamp(-0.7, 0.7);

    // Penalise candidates carrying extra distinctive Latin tokens the title does
    // NOT have — these are usually spin-offs/compilations (e.g. "Spin-off",
    // "8th anniversary") or plain different shows sharing one word.
    let title_toks: std::collections::HashSet<String> = latin_tokens(raw_title)
        .into_iter()
        .map(|t| t.to_lowercase())
        .collect();
    let mut extra: f64 = 0.0;
    let mut cand_distinctive: std::collections::HashSet<String> = std::collections::HashSet::new();
    for t in latin_tokens(&cand.name)
        .into_iter()
        .chain(latin_tokens(&cand.name_cn))
    {
        let t = t.to_lowercase();
        if t.len() >= 3 && !GENERIC_TOKENS.contains(&t.as_str()) {
            if !title_toks.contains(&t) && !cand_distinctive.contains(&t) {
                extra += 1.0;
            }
            cand_distinctive.insert(t);
        }
    }
    sim -= (extra * 0.15).min(0.6);

    // And the mirror: when the candidate's name is itself mostly Latin text,
    // the TITLE's distinctive words should appear in it — "This Way Up" or
    // "Cosmic Baton Girl" sharing one word with a long romaji title is a
    // different show. JP/CN-named candidates are exempt (romaji title vs
    // kanji name with zero overlap is the normal correct case).
    let latinish = |s: &str| {
        let total = s.chars().filter(|c| c.is_alphanumeric()).count();
        if total == 0 {
            return false;
        }
        let ascii = s.chars().filter(|c| c.is_ascii_alphanumeric()).count();
        ascii * 10 >= total * 6
    };
    let cand_is_latin = latinish(&cand.name) || latinish(&cand.name_cn);
    let mut missing_title_tokens: f64 = 0.0;
    for t in latin_tokens(raw_title) {
        let t = t.to_lowercase();
        if t.len() >= 3
            && !GENERIC_TOKENS.contains(&t.as_str())
            && !t.chars().any(|c| c.is_ascii_digit())
            && !name_blob.contains(&t)
        {
            missing_title_tokens += 1.0;
        }
    }
    if !cand_distinctive.is_empty() && cand_is_latin {
        sim -= (missing_title_tokens * 0.2).min(0.5);
    }

    // When the title contains CJK, a candidate whose own CJK text is mostly
    // absent from the title is a different show that merely shares a Latin
    // word (e.g. "宝石宠物 Sunshine" matching "…Watanare Next Sunshine") —
    // penalise by the fraction of missing CJK chars, using the better of
    // name/name_cn.
    let title_cjk: std::collections::HashSet<char> = norm_title
        .chars()
        .filter(|c| (*c as u32) > 0x2E7F)
        .collect();
    if !title_cjk.is_empty() {
        let miss_frac = |n: &str| {
            let chars: Vec<char> = n.chars().filter(|c| (*c as u32) > 0x2E7F).collect();
            if chars.len() < 2 {
                return 0.0;
            }
            let missing = chars.iter().filter(|c| !title_cjk.contains(c)).count();
            missing as f64 / chars.len() as f64
        };
        sim -= 0.5 * miss_frac(&n_name).min(miss_frac(&n_cn));
    }

    // A candidate whose entire name is a tiny fragment of the title can rack up
    // containment + token bonuses while explaining almost none of the title.
    let cand_len = n_name.chars().count().max(n_cn.chars().count());
    let t_len = norm_title.chars().count();
    if cand_len * 3 < t_len && !shared_digit_token {
        sim = sim.min(0.45);
    }

    // Season discrimination: when the title names a season, a candidate naming
    // a DIFFERENT season is the wrong entry no matter how similar the rest is
    // ("…S04E10" files once landed inside the season-3 entry). A candidate
    // with no season marker is usually the season-1/base entry — also wrong
    // for an explicit season ≥2, but less certainly.
    if let Some(ts) = season_marker(raw_title) {
        let cs = season_marker(&cand.name).or_else(|| season_marker(&cand.name_cn));
        match cs {
            Some(c) if c == ts => sim += 0.35,
            Some(_) => sim -= 0.5,
            None => {
                if ts >= 2 {
                    sim -= 0.25;
                }
            }
        }
    }

    if coverage >= 0.85 {
        // Full-title query: the API's #1 hit for the complete title is right
        // far more often than our text similarity can tell (romaji title vs
        // kanji names has zero overlap), so the top hit gets a dominant prior
        // and later hits only a small one — they must win on real evidence.
        let prior = if hit_idx == 0 {
            full_base
        } else {
            (0.16 - 0.03 * (hit_idx as f64 - 1.0)).max(0.0)
        };
        sim += prior;
    } else {
        // Truncated-keyword hit: no prior, and unless anchored by a shared
        // digit-bearing token (the "U149" case), demand strong raw text
        // overlap — a shared English word plus its bonus is NOT enough. A
        // mostly-Latin candidate must also cover every distinctive title
        // word: "Defective Detective" has high bigram noise against
        // "Star-Detective Precure" but is missing "precure".
        if !shared_digit_token
            && (raw_overlap < 0.65 || (cand_is_latin && missing_title_tokens > 0.0))
        {
            return sim.min(0.2);
        }
        sim -= 0.10 * (1.0 - coverage);
        sim -= 0.02 * hit_idx as f64;
    }

    sim
}

const GENERIC_TOKENS: &[&str] = &[
    "the", "and", "from", "season", "part", "movie", "tv", "ova", "special", "girls", "boys",
    "story", "world", "life", "love", "no", "wa", "to", "ni", "star", "next", "new", "girl",
    "this", "that",
];

/// Extract a season number from a title or subject name: "Season 4",
/// "4th season", "S04", "第四季", "第4季". Returns None when no marker.
fn season_marker(s: &str) -> Option<u32> {
    static RE_EN: Lazy<regex::Regex> = Lazy::new(|| {
        regex::Regex::new(
            r"(?i)(?:season\s*(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s*season|\bS(\d{2})\b)",
        )
        .unwrap()
    });
    static RE_CJK: Lazy<regex::Regex> =
        Lazy::new(|| regex::Regex::new(r"第\s*([0-9一二三四五六七八九十]{1,3})\s*[季期]").unwrap());
    if let Some(c) = RE_EN.captures(s) {
        let g = c.get(1).or_else(|| c.get(2)).or_else(|| c.get(3))?;
        return g.as_str().parse().ok();
    }
    if let Some(c) = RE_CJK.captures(s) {
        let v = c.get(1)?.as_str();
        if let Ok(n) = v.parse::<u32>() {
            return Some(n);
        }
        return match v {
            "一" => Some(1),
            "二" => Some(2),
            "三" => Some(3),
            "四" => Some(4),
            "五" => Some(5),
            "六" => Some(6),
            "七" => Some(7),
            "八" => Some(8),
            "九" => Some(9),
            "十" => Some(10),
            _ => None,
        };
    }
    None
}

/// Extract alnum tokens from a title, splitting on separators/spaces but keeping
/// letter+digit combos whole, e.g. "U149" / "0080" / "Gundam".
fn latin_tokens(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_string())
        .collect()
}

/// Rough similarity: fraction of the shorter string's character-bigrams that
/// appear in the other. Cheap and good enough to disambiguate candidates.
fn overlap(a: &str, b: &str) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    // Direct containment is a strong signal, scaled by how much of the longer
    // string is covered — a short fragment contained in a long title (or vice
    // versa) is weak evidence, near-equal strings are near-exact.
    if b.contains(a) || a.contains(b) {
        let la = a.chars().count() as f64;
        let lb = b.chars().count() as f64;
        let ratio = la.min(lb) / la.max(lb);
        return 0.15 + 0.85 * ratio;
    }
    let ab = bigrams(a);
    let bb = bigrams(b);
    if ab.is_empty() || bb.is_empty() {
        return 0.0;
    }
    // Fraction of the shorter string's UNIQUE bigrams found in the longer one.
    // (Counting the longer side's duplicate bigrams against the shorter length
    // once scored "This Way Up" a perfect 1.0 against a 50-char title.)
    let (short, long) = if ab.len() <= bb.len() {
        (&ab, &bb)
    } else {
        (&bb, &ab)
    };
    let uniq: std::collections::HashSet<&String> = short.iter().collect();
    let common = uniq.iter().filter(|g| long.contains(**g)).count();
    common as f64 / uniq.len() as f64
}

fn bigrams(s: &str) -> Vec<String> {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() < 2 {
        return vec![s.to_string()];
    }
    chars.windows(2).map(|w| w.iter().collect()).collect()
}

/// Fetch full subject detail by id.
pub async fn subject(id: i64) -> Result<BangumiSubject> {
    let url = format!("{}/v0/subjects/{id}", api_base());
    let client = client()?;
    let resp = send_with_backoff(|| auth(client.get(&url)), "bangumi subject").await?;
    if !resp.status().is_success() {
        anyhow::bail!("bangumi subject failed: {}", resp.status());
    }
    let raw: RawSubject = resp.json().await.context("parse bangumi subject")?;
    Ok(raw.into())
}

pub fn has_token() -> bool {
    TOKEN.lock().unwrap().is_some()
}

// ---- OAuth 2.0 (authorization code flow) ----
//
// Bangumi's OAuth endpoints live on the main site (bgm.tv/oauth), not the API
// host. Flow: open `authorize_url()` in a browser, user approves, Bangumi
// redirects to the registered callback with `?code=...`, then we exchange the
// code for an access + refresh token via `exchange_code()`.
// Docs: https://github.com/bangumi/api/blob/master/docs-raw/How-to-Auth.md

/// Build the browser authorization URL for the given app id and callback.
///
/// Only this page follows the login route choice. The code exchange afterwards
/// is always official: see `oauth_post`.
pub fn authorize_url(client_id: &str, redirect_uri: &str) -> String {
    format!(
        "{}/authorize?client_id={}&response_type=code&redirect_uri={}",
        oauth_page_base(),
        urlencode(client_id),
        urlencode(redirect_uri),
    )
}

/// The token payload returned by the OAuth token endpoint. Field names match
/// Bangumi's JSON so it deserializes directly. Deliberately not `Debug`: this
/// value holds credentials that must never reach a log or panic message.
#[derive(Clone, Deserialize)]
pub struct OAuthToken {
    pub access_token: String,
    pub refresh_token: String,
    /// Lifetime in seconds (Bangumi returns ~604800 = 7 days).
    pub expires_in: i64,
    #[serde(default)]
    pub user_id: i64,
}

#[derive(Deserialize)]
struct RawOAuthToken {
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
    #[serde(default)]
    user_id: serde_json::Value,
    error: Option<String>,
    token_type: Option<String>,
}

/// Map a provider error code onto a fixed, client-safe set. Unknown codes and
/// any provider-authored text are collapsed into `unknown_error` so a response
/// body can never be reflected into the UI.
fn oauth_protocol_error(code: &str) -> anyhow::Error {
    let known = match code {
        "invalid_grant"
        | "invalid_token"
        | "invalid_client"
        | "invalid_request"
        | "access_denied"
        | "unauthorized_client"
        | "server_error"
        | "temporarily_unavailable"
        | "unsupported_grant_type" => code,
        _ => "unknown_error",
    };
    anyhow::anyhow!("oauth error: {known}")
}

impl RawOAuthToken {
    fn into_token(self) -> Result<OAuthToken> {
        if let Some(err) = self.error {
            return Err(oauth_protocol_error(&err));
        }
        let user_id = match self.user_id {
            serde_json::Value::Number(n) => n.as_i64().unwrap_or(0),
            serde_json::Value::String(s) => s.parse().unwrap_or(0),
            _ => 0,
        };
        // Bangumi returns a 7-day token; treat an absent or absurd lifetime as
        // a malformed response rather than silently storing an expired token.
        let access_token = self
            .access_token
            .filter(|v| !v.trim().is_empty())
            .context("oauth response missing access_token")?;
        let refresh_token = self
            .refresh_token
            .filter(|v| !v.trim().is_empty())
            .context("oauth response missing refresh_token")?;
        let expires_in = self
            .expires_in
            .filter(|v| *v > 0 && *v <= 366 * 86400)
            .context("oauth response invalid expires_in")?;
        if !self
            .token_type
            .as_deref()
            .is_some_and(|v| v.eq_ignore_ascii_case("bearer"))
        {
            anyhow::bail!("oauth response invalid token_type");
        }
        Ok(OAuthToken {
            access_token,
            refresh_token,
            expires_in,
            user_id,
        })
    }
}

/// Exchange an authorization `code` for an access + refresh token.
///
/// The `state` echoed back here is the same value the app sent to `/authorize`
/// and already validated against the callback.
pub async fn exchange_code(
    client_id: &str,
    client_secret: &str,
    code: &str,
    redirect_uri: &str,
    state: &str,
) -> Result<OAuthToken> {
    let params = [
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("code", code),
        ("redirect_uri", redirect_uri),
        ("state", state),
    ];
    let mut token = post_token(&params).await?;
    // The exchange alone only proves *a* token was issued. token_status proves
    // it belongs to this client, is still valid, and reports the user id the
    // refresh response omits.
    let status = oauth_post(
        "token_status",
        &[("access_token", token.access_token.as_str())],
    )
    .await?;
    validate_token_status(&status, client_id, &mut token)?;
    Ok(token)
}

/// Refresh an expired access token using the stored refresh token.
pub async fn refresh_token(
    client_id: &str,
    client_secret: &str,
    refresh: &str,
    redirect_uri: &str,
) -> Result<OAuthToken> {
    let params = [
        ("grant_type", "refresh_token"),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("refresh_token", refresh),
        ("redirect_uri", redirect_uri),
    ];
    post_token(&params).await
}

async fn post_token(params: &[(&str, &str)]) -> Result<OAuthToken> {
    let value = oauth_post("access_token", params).await?;
    let raw: RawOAuthToken = serde_json::from_value(value)
        .map_err(|_| anyhow::anyhow!("oauth response invalid fields"))?;
    raw.into_token()
}

/// Parse a token-endpoint response without ever logging or echoing its body:
/// a successful body contains the access and refresh tokens themselves.
fn parse_oauth_response(status: reqwest::StatusCode, body: &[u8]) -> Result<serde_json::Value> {
    let value: serde_json::Value = serde_json::from_slice(body)
        .map_err(|_| anyhow::anyhow!("oauth response invalid JSON (http {})", status.as_u16()))?;
    if let Some(error) = value["error"].as_str() {
        return Err(oauth_protocol_error(error));
    }
    if !status.is_success() {
        anyhow::bail!("oauth request http {}", status.as_u16());
    }
    Ok(value)
}

/// POST to the OAuth endpoints with a dedicated client.
///
/// Deliberately separate from the shared `client()`: that client follows up to
/// ten redirects, and a redirect on a form POST can drop the body or change the
/// method, which turns a valid exchange into an unexplained failure. The token
/// endpoints also need `Accept: application/json`, otherwise Rails may answer
/// with HTML that cannot be parsed.
///
/// Always posts to the official endpoint, even when the authorization page was
/// opened through the reverse proxy: Anubis answers a server-side POST on
/// `bangumi.vip/oauth/*` with a challenge page, so that route can never
/// exchange a code. A code issued after a proxied authorization is accepted
/// here because it comes from the same Bangumi account, not from the host that
/// rendered the form.
async fn oauth_post(endpoint: &str, params: &[(&str, &str)]) -> Result<serde_json::Value> {
    let mut builder = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30));
    if let Some(proxy) = detect_system_proxy() {
        builder = builder.proxy(reqwest::Proxy::all(proxy).context("oauth proxy configuration")?);
    }
    let mut resp = builder
        .build()
        .context("oauth client initialization")?
        .post(format!("{OAUTH_OFFICIAL}/{endpoint}"))
        .header(reqwest::header::ACCEPT, "application/json")
        .form(params)
        .send()
        .await
        .map_err(|_| anyhow::anyhow!("oauth token request failed"))?;
    let status = resp.status();
    // Bound the read: an HTML error page or a proxy captive portal must not be
    // buffered without limit.
    let mut body = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| anyhow::anyhow!("oauth token request failed"))?
    {
        if body.len().saturating_add(chunk.len()) > 64 * 1024 {
            anyhow::bail!("oauth response too large");
        }
        body.extend_from_slice(&chunk);
    }
    parse_oauth_response(status, &body)
}

/// Confirm the freshly issued token really belongs to this client and is live.
///
/// `token_status` returns the client id, an absolute expiry and the user id;
/// the documented refresh response omits `user_id`, so this is also where a
/// refreshed session recovers its identity.
fn validate_token_status(
    value: &serde_json::Value,
    client_id: &str,
    token: &mut OAuthToken,
) -> Result<()> {
    let number = |v: &serde_json::Value| {
        v.as_i64()
            .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
    };
    let client = value["client_id"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| value["client_id"].as_i64().map(|v| v.to_string()));
    let user_id = number(&value["user_id"]).filter(|v| *v > 0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    let expires = number(&value["expires"]).filter(|v| *v > now);
    if client.as_deref() != Some(client_id)
        || user_id.is_none()
        || expires.is_none()
        || value["access_token"].as_str() != Some(token.access_token.as_str())
        || (token.user_id > 0 && Some(token.user_id) != user_id)
    {
        anyhow::bail!("oauth token verification failed");
    }
    token.user_id = user_id.unwrap();
    // Trust whichever lifetime is shorter.
    token.expires_in = token.expires_in.min(expires.unwrap() - now);
    Ok(())
}

// ---- Collection endpoints ----

#[derive(Deserialize)]
struct RawCollection {
    #[serde(rename = "type", default)]
    kind: Option<i64>,
}

#[derive(Deserialize)]
struct RawUserCollection {
    subject_id: i64,
    #[serde(rename = "type", default)]
    kind: i64,
}

#[derive(Deserialize)]
struct CollectionPage {
    #[serde(default)]
    data: Vec<RawUserCollection>,
    total: i64,
    #[serde(default)]
    limit: i64,
    #[serde(default)]
    offset: i64,
}

/// Validate one page of a collection listing. A failure here must reach the
/// caller: silently returning the pages fetched so far would let the UI report
/// a complete sync while the library is only partially updated.
///
/// A 404 on the *first* page is the endpoint's answer for an account with no
/// collections and is reported as an empty page; later 404s are real failures.
fn parse_collection_page(
    status: reqwest::StatusCode,
    body: &[u8],
    offset: i64,
) -> Result<Option<CollectionPage>> {
    if status == reqwest::StatusCode::NOT_FOUND && offset == 0 {
        return Ok(None);
    }
    if !status.is_success() {
        anyhow::bail!("bangumi collections http {}", status.as_u16());
    }
    let page: CollectionPage = serde_json::from_slice(body)
        .map_err(|_| anyhow::anyhow!("bangumi collections invalid response"))?;
    if page.offset != offset || page.total < 0 || (page.data.is_empty() && offset < page.total) {
        anyhow::bail!("bangumi collections incomplete page");
    }
    Ok(Some(page))
}

/// Fetch all anime subjects the user has collected, as (subject_id, type).
/// type: 1=想看, 2=看过, 3=在看, 4=搁置, 5=抛弃.
/// Requires a token; returns empty vec when unauthenticated.
pub async fn all_collections() -> Result<Vec<(i64, i64)>> {
    if !has_token() {
        return Ok(Vec::new());
    }
    // Read endpoints need the real username; `-` only works for writes.
    let username = current_username().await?;
    let mut out = Vec::new();
    let limit = 50u32;
    let mut offset = 0i64;
    let client = client()?;
    loop {
        let url = format!(
            "{}/v0/users/{username}/collections?subject_type=2&limit={limit}&offset={offset}",
            collection_base()
        );
        let resp = send_with_backoff(
            || collection_auth(client.get(&url)),
            "bangumi all_collections",
        )
        .await?;
        let Some(page) = parse_collection_page(resp.status(), &resp.bytes().await?, offset)? else {
            return Ok(out);
        };
        for item in &page.data {
            if item.kind > 0 {
                out.push((item.subject_id, item.kind));
            }
        }
        offset += page.data.len() as i64;
        if offset >= page.total || page.data.is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    Ok(out)
}

/// The logged-in user's collection type for ONE subject (fast, for just-bound entries).
pub async fn collection_status(subject_id: i64) -> Result<Option<i64>> {
    if !has_token() {
        return Ok(None);
    }
    // Read endpoint needs the real username; `-` only works for writes.
    let username = current_username().await?;
    let url = format!(
        "{}/v0/users/{username}/collections/{subject_id}",
        collection_base()
    );
    let client = client()?;
    let resp =
        send_with_backoff(|| collection_auth(client.get(&url)), "bangumi collection").await?;
    match resp.status().as_u16() {
        404 | 401 | 403 => Ok(None),
        s if (200..300).contains(&s) => {
            let raw: RawCollection = resp.json().await.context("parse bangumi collection")?;
            Ok(raw.kind)
        }
        s => anyhow::bail!("bangumi collection failed: {s}"),
    }
}

/// Update (or create) the user's collection for a subject.
/// collection_type: 1=想看, 2=看过, 3=在看, 4=搁置, 5=抛弃.
///
/// Uses POST, which both creates a new collection (202) and updates an existing
/// one. PATCH only works on already-collected subjects (404 "subject not
/// collected" otherwise), so POST is the single correct verb for both cases.
pub async fn update_collection(subject_id: i64, collection_type: i64) -> Result<()> {
    if !has_token() {
        anyhow::bail!("no token set");
    }
    let url = format!("{}/v0/users/-/collections/{subject_id}", collection_base());
    let body = serde_json::json!({ "type": collection_type });
    let client = client()?;
    let resp = send_with_backoff(
        || collection_auth(client.post(&url).json(&body)),
        "bangumi update_collection",
    )
    .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("bangumi update_collection failed: {status} {text}");
    }
    Ok(())
}

// ---- Episode titles from Bangumi ----

#[derive(Deserialize)]
struct RawEpisodePage {
    #[serde(default)]
    data: Vec<RawEpisode>,
}

#[derive(Deserialize)]
struct RawEpisode {
    /// 0=本篇, 1=SP, 2=OP, 3=ED, 4=预告CM, 5=MAD, 6=其他
    #[serde(rename = "type", default)]
    kind: i64,
    #[serde(default)]
    ep: Option<f64>,
    #[serde(default)]
    name: String,
    #[serde(default)]
    name_cn: String,
}

pub struct EpisodeTitle {
    pub ep: i64,
    pub name: String,
    pub name_cn: String,
}

/// Fetch episode titles for a subject's main episodes (type=0).
pub async fn subject_episode_titles(subject_id: i64, limit: u32) -> Result<Vec<EpisodeTitle>> {
    let url = format!(
        "{}/v0/subjects/{subject_id}/episodes?type=0&limit={limit}",
        api_base()
    );
    let client = client()?;
    let resp = send_with_backoff(|| auth(client.get(&url)), "bangumi episode titles").await?;
    if !resp.status().is_success() {
        return Ok(Vec::new());
    }
    let page: RawEpisodePage = match resp.json().await {
        Ok(p) => p,
        Err(_) => return Ok(Vec::new()),
    };
    Ok(page
        .data
        .into_iter()
        .filter(|e| e.kind == 0)
        .filter_map(|e| {
            let n = e.ep? as i64;
            Some(EpisodeTitle {
                ep: n,
                name: e.name,
                name_cn: e.name_cn,
            })
        })
        .collect())
}

#[cfg(test)]
mod match_tests {
    use super::*;

    #[test]
    fn mirror_only_accepts_anubis_cookie_headers() {
        assert!(validate_challenge_cookie("").is_ok());
        assert!(validate_challenge_cookie(
            "techaro.lol-anubis-auth=proof; techaro.lol-anubis-cookie-verification=ok"
        )
        .is_ok());
        assert!(validate_challenge_cookie("session=account").is_err());
        assert!(
            validate_challenge_cookie("techaro.lol-anubis-auth=proof\r\nX-Injected: value")
                .is_err()
        );
        assert!(validate_challenge_cookie("techaro.lol-anubis-auth=").is_err());
    }

    #[test]
    fn mirror_and_unknown_requests_never_receive_bearer() {
        let c = reqwest::Client::new();
        let mirror = auth(c.get(format!("{BASE_MIRROR}/v0/subjects/1")))
            .build()
            .unwrap();
        assert!(!mirror
            .headers()
            .contains_key(reqwest::header::AUTHORIZATION));
        let unknown = auth(c.get("https://example.invalid/v0/me"))
            .build()
            .unwrap();
        assert!(!unknown
            .headers()
            .contains_key(reqwest::header::AUTHORIZATION));
        assert!(!unknown.headers().contains_key(reqwest::header::COOKIE));
    }

    #[test]
    fn desktop_proxy_prefers_https_and_requires_manual_mode() {
        let https = ("127.0.0.1".to_string(), 7890);
        let http = ("127.0.0.1".to_string(), 8080);
        assert_eq!(
            desktop_proxy_from_values("'manual'", Some(&https), Some(&http)),
            Some("http://127.0.0.1:7890".to_string())
        );
        assert_eq!(
            desktop_proxy_from_values("'none'", Some(&https), Some(&http)),
            None
        );
    }

    #[test]
    fn desktop_proxy_falls_back_to_http_and_formats_ipv6() {
        let empty_https = (String::new(), 0);
        let http = ("::1".to_string(), 7890);
        assert_eq!(
            desktop_proxy_from_values("manual", Some(&empty_https), Some(&http)),
            Some("http://[::1]:7890".to_string())
        );
    }

    fn subj(id: i64, name: &str, cn: &str) -> BangumiSubject {
        BangumiSubject {
            id,
            name: name.into(),
            name_cn: cn.into(),
            summary: String::new(),
            cover_url: None,
            air_date: None,
            eps: None,
            rating: None,
            rating_total: None,
            rating_rank: None,
            rating_counts: None,
            tags: Vec::new(),
            tag_counts: None,
        }
    }

    #[test]
    fn subject_keeps_per_entry_tag_counts() {
        let raw: RawSubject = serde_json::from_str(
            r#"{
                "id": 42,
                "tags": [
                    {"name": "校园", "count": 328, "total_count": 999},
                    {"name": "日常", "count": 215}
                ]
            }"#,
        )
        .unwrap();
        let subject = BangumiSubject::from(raw);

        assert_eq!(subject.tags, vec!["校园", "日常"]);
        let counts: serde_json::Value =
            serde_json::from_str(subject.tag_counts.as_deref().unwrap()).unwrap();
        assert_eq!(counts[0]["count"], 328);
        assert_eq!(counts[1]["count"], 215);
        assert!(counts[0].get("total_count").is_none());
    }

    #[test]
    fn variants_generated() {
        let v = keyword_variants("Hina Logi from Luck & Logic");
        assert!(v.iter().any(|s| s == "Hina Logi from Luck & Logic"));
        assert!(v.iter().any(|s| s.eq_ignore_ascii_case("Hina Logi")));
        assert!(v.iter().any(|s| s.eq_ignore_ascii_case("Luck Logic")));
    }

    /// The route flags are process-wide, so any test that flips them has to
    /// hold this lock; otherwise parallel tests observe each other's choices.
    /// A failed assertion poisons the lock, so recover the inner guard instead
    /// of turning one failure into three.
    static ROUTE_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn route_test_guard() -> std::sync::MutexGuard<'static, ()> {
        ROUTE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn reset_routes() {
        set_route_options(false, false);
        MIRROR.store(false, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn oauth_authorize_url_keeps_encoded_custom_scheme_redirect() {
        let _guard = route_test_guard();
        reset_routes();
        let url = authorize_url("client id", "kurako://oauth/callback");
        assert_eq!(
            url,
            "https://bgm.tv/oauth/authorize?client_id=client%20id&response_type=code&redirect_uri=kurako%3A%2F%2Foauth%2Fcallback"
        );
    }

    #[test]
    fn oauth_page_route_switches_only_the_authorization_page() {
        let _guard = route_test_guard();
        reset_routes();
        MIRROR.store(true, std::sync::atomic::Ordering::Relaxed);
        let callback = "kurako://oauth/callback";

        // Both flags off: the page stays official even with the proxy enabled.
        assert!(authorize_url("id", callback).starts_with("https://bgm.tv/oauth/authorize"));

        set_route_options(true, false);
        assert!(authorize_url("id", callback).starts_with("https://bangumi.vip/oauth/authorize"));
        // Login opt-in must not move collections.
        assert_eq!(collection_base(), BASE_OFFICIAL);

        set_route_options(false, true);
        assert!(authorize_url("id", callback).starts_with("https://bgm.tv/oauth/authorize"));
        assert_eq!(collection_base(), BASE_MIRROR);

        // A route flag alone never enables the proxy.
        MIRROR.store(false, std::sync::atomic::Ordering::Relaxed);
        assert!(authorize_url("id", callback).starts_with("https://bgm.tv/oauth/authorize"));
        assert_eq!(collection_base(), BASE_OFFICIAL);
        reset_routes();
    }

    #[test]
    fn collection_auth_attaches_bearer_only_to_a_known_host() {
        let _guard = route_test_guard();
        reset_routes();
        set_token(Some("route-test-token".into()));
        let client = reqwest::Client::new();
        for host in ["https://api.bangumi.vip", "https://api.bgm.tv"] {
            let request = collection_auth(client.get(format!("{host}/v0/me")))
                .build()
                .unwrap();
            assert_eq!(
                request
                    .headers()
                    .get(reqwest::header::AUTHORIZATION)
                    .and_then(|v| v.to_str().ok()),
                Some("Bearer route-test-token"),
                "{host} should receive the bearer"
            );
        }
        // Credentials must not follow a route to an unrelated host.
        let request = collection_auth(client.get("https://example.com/"))
            .build()
            .unwrap();
        assert!(request
            .headers()
            .get(reqwest::header::AUTHORIZATION)
            .is_none());
        set_token(None);
    }

    const V0: f64 = 0.55; // full-title v0 hit-0 prior

    #[test]
    fn scores_correct_candidate_higher() {
        let raw = "Hina Logi from Luck & Logic";
        let title = normalize_for_match(raw);
        let correct = subj(
            175362,
            "ひなろじ 〜from Luck & Logic〜",
            "雏逻辑 〜from Luck & Logic〜",
        );
        let wrong = subj(2121, "ラブひな", "爱情房东俏房客");
        // correct found at rank 3 of the full-title query, wrong at rank 0
        let sc = score_candidate(&title, raw, &correct, 1.0, V0, 3);
        let sw = score_candidate(&title, raw, &wrong, 1.0, V0, 0);
        assert!(sc > sw, "correct {sc} should beat wrong {sw}");
        assert!(sc >= 0.38, "correct must clear accept floor, got {sc}");
    }

    #[test]
    fn u149_exact() {
        let raw = "THE IDOLM@STER CINDERELLA GIRLS U149";
        let title = normalize_for_match(raw);
        let correct = subj(
            376703,
            "アイドルマスター シンデレラガールズ U149",
            "偶像大师 灰姑娘 U149",
        );
        let s = score_candidate(&title, raw, &correct, 1.0, V0, 0);
        assert!(s > 0.4, "got {s}");
    }

    #[test]
    fn full_title_rank_prior_clears_floor_without_text_overlap() {
        // Romaji title, JP/CN candidate names: zero text overlap, but a #1 hit
        // on the full-title query must still be accepted.
        let raw = "Maebashi Witches";
        let title = normalize_for_match(raw);
        let correct = subj(511207, "前橋ウィッチーズ", "前桥魔女");
        let s = score_candidate(&title, raw, &correct, 1.0, V0, 0);
        assert!(s >= 0.38, "got {s}");
    }

    #[test]
    fn full_title_top_hit_beats_word_sharing_later_hit() {
        // "Cosmic Princess Kaguya": correct 超时空辉夜姬 is v0 hit 0 with zero
        // text overlap; "Cosmic Baton Girl コメットさん" at hit 1 shares the
        // word "Cosmic" — the top hit must still win.
        let raw = "Cosmic Princess Kaguya";
        let title = normalize_for_match(raw);
        let correct = subj(604826, "コズミック☆プリンセスかぐや!", "超时空辉夜姬！");
        let comet = subj(14646, "Cosmic Baton Girl コメットさん☆", "彗星公主");
        let sc = score_candidate(&title, raw, &correct, 1.0, V0, 0);
        let sw = score_candidate(&title, raw, &comet, 1.0, V0, 1);
        assert!(sc > sw, "correct {sc} should beat comet {sw}");

        // Same shape: STAR DRIVER at hit 1 vs 名侦探光之美少女 at hit 0.
        let raw2 = "Star-Detective Precure";
        let title2 = normalize_for_match(raw2);
        let correct2 = subj(611077, "キミとアイドルプリキュア♪", "名侦探光之美少女！");
        let driver = subj(7348, "STAR DRIVER 輝きのタクト", "驭星者 闪亮的拓人");
        let sc2 = score_candidate(&title2, raw2, &correct2, 1.0, V0, 0);
        let sw2 = score_candidate(&title2, raw2, &driver, 1.0, V0, 1);
        assert!(sc2 > sw2, "correct {sc2} should beat star driver {sw2}");
    }

    #[test]
    fn truncated_variant_fragment_is_gated() {
        // Junk discovered via a truncated keyword must NOT clear the floor:
        // "ANOTHER WORLD" found via the "Another World" fragment of Re:Zero.
        let raw = "ReZERO Starting Life in Another World";
        let title = normalize_for_match(raw);
        let junk = subj(1, "ANOTHER WORLD", "");
        let s = score_candidate(&title, raw, &junk, 0.38, V0, 0);
        assert!(s < 0.38, "junk must be gated, got {s}");

        // The Isekai Quartet movie also carries "Another World" in its name.
        let junk1b = subj(
            303126,
            "劇場版 異世界かるてっと ～あなざーわーるど～",
            "剧场版 异世界四重奏 ～Another World～",
        );
        let s1b = score_candidate(&title, raw, &junk1b, 0.38, V0, 0);
        assert!(s1b < 0.38, "quartet movie must be gated, got {s1b}");

        // "Tentacle Witches" via the "Witches" fragment of Maebashi Witches.
        let raw2 = "Maebashi Witches";
        let title2 = normalize_for_match(raw2);
        let junk2 = subj(2, "Tentacle Witches", "触手和巫女");
        let s2 = score_candidate(&title2, raw2, &junk2, 0.47, V0, 0);
        assert!(s2 < 0.38, "junk must be gated, got {s2}");

        // "GoBots: Battle of the Rock Lords" via "the Rock" from Bocchi.
        let raw3 = "Bocchi the Rock!";
        let title3 = normalize_for_match(raw3);
        let junk3 = subj(387970, "GoBots: Battle of the Rock Lords", "百变雄师剧场版");
        let s3 = score_candidate(&title3, raw3, &junk3, 0.55, V0, 0);
        assert!(s3 < 0.38, "junk must be gated, got {s3}");

        // "The Bird Store" via "Blue Bird" from Liz and the Blue Bird.
        let raw4 = "Liz and the Blue Bird";
        let title4 = normalize_for_match(raw4);
        let junk4 = subj(149118, "The Bird Store", "鸟店");
        let s4 = score_candidate(&title4, raw4, &junk4, 0.5, V0, 0);
        assert!(s4 < 0.38, "junk must be gated, got {s4}");
    }

    #[test]
    fn digit_token_bypasses_gate() {
        // The "U149" fragment query is legitimate because the shared
        // digit-bearing token is a near-unique identifier.
        let raw = "THE IDOLM@STER CINDERELLA GIRLS U149";
        let title = normalize_for_match(raw);
        let correct = subj(
            376703,
            "アイドルマスター シンデレラガールズ U149",
            "偶像大师 灰姑娘 U149",
        );
        let s = score_candidate(&title, raw, &correct, 0.13, V0, 0);
        assert!(s >= 0.38, "got {s}");
    }

    #[test]
    fn season_mismatch_rejected() {
        // S04 files must not land in the season-3 entry: the API ranks the
        // 3rd-season subject first for this query, but the season marker
        // disagrees, so it must fall below the accept floor.
        let raw = "ReZERO Starting Life in Another World Season 4";
        let title = normalize_for_match(raw);
        let s3 = subj(
            425998,
            "Re:ゼロから始める異世界生活 3rd season 襲擊編",
            "Re：从零开始的异世界生活 第三季 袭击篇",
        );
        let base = subj(
            140001,
            "Re:ゼロから始める異世界生活",
            "Re：从零开始的异世界生活",
        );
        let s4 = subj(
            547888,
            "Re:ゼロから始める異世界生活 4th season",
            "Re：从零开始的异世界生活 第四季 丧失篇",
        );
        let sc3 = score_candidate(&title, raw, &s3, 1.0, V0, 0);
        let scb = score_candidate(&title, raw, &base, 1.0, V0, 3);
        let sc4 = score_candidate(&title, raw, &s4, 1.0, V0, 4);
        assert!(sc3 < 0.38, "wrong season must be rejected, got {sc3}");
        assert!(
            scb < 0.38,
            "base entry must not absorb explicit S4, got {scb}"
        );
        assert!(
            sc4 > sc3 && sc4 > scb,
            "matching season must win: s4={sc4} s3={sc3} base={scb}"
        );
    }

    #[test]
    fn season_markers_parsed() {
        assert_eq!(season_marker("Foo Season 4"), Some(4));
        assert_eq!(season_marker("Foo 3rd season Bar"), Some(3));
        assert_eq!(
            season_marker("Re：从零开始的异世界生活 第三季 袭击篇"),
            Some(3)
        );
        assert_eq!(
            season_marker("Re：从零开始的异世界生活 第四季 丧失篇"),
            Some(4)
        );
        assert_eq!(season_marker("Mob Psycho 100"), None);
        assert_eq!(season_marker("THE IDOLM@STER CINDERELLA GIRLS U149"), None);
    }

    #[test]
    fn shared_stopword_junk_loses_to_top_hit() {
        // "This Way Up" shares only the stopword "This" with the title; the
        // zero-overlap #1 hit must still win, and the junk must sink below
        // the floor on its missing-token penalty.
        let raw = "This Monster Wants To Eat Me - Watashi wo Tabetai, Hitodenashi";
        let title = normalize_for_match(raw);
        let correct = subj(520842, "私を喰べたい、ひとでなし", "对我垂涎欲滴的非人少女");
        let junk = subj(160678, "This Way Up", "厄运葬礼");
        // legacy full-title list: correct at hit 0, junk at hit 2
        let sc = score_candidate(&title, raw, &correct, 1.0, 0.42, 0);
        let sj = score_candidate(&title, raw, &junk, 1.0, 0.42, 2);
        assert!(sc > sj, "correct {sc} must beat junk {sj}");
        assert!(sj < 0.38, "junk must sink below floor, got {sj}");
    }
}

#[cfg(test)]
mod oauth_tests {
    use super::*;

    fn raw(json: &str) -> RawOAuthToken {
        serde_json::from_str(json).unwrap()
    }

    fn token() -> OAuthToken {
        OAuthToken {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_in: 604800,
            user_id: 0,
        }
    }

    #[test]
    fn protocol_errors_are_allowlisted() {
        for known in [
            "invalid_grant",
            "invalid_token",
            "invalid_client",
            "invalid_request",
            "access_denied",
            "unauthorized_client",
            "server_error",
            "temporarily_unavailable",
            "unsupported_grant_type",
        ] {
            assert_eq!(
                oauth_protocol_error(known).to_string(),
                format!("oauth error: {known}")
            );
        }
        // Provider-authored text and unknown codes must never be reflected.
        let injected = oauth_protocol_error("<b>invalid</b> secret-token").to_string();
        assert_eq!(injected, "oauth error: unknown_error");
        assert!(!injected.contains("secret-token"));
    }

    #[test]
    fn token_response_requires_real_credentials() {
        let ok = raw(
            r#"{"access_token":"a","refresh_token":"r","expires_in":604800,
                "token_type":"Bearer","user_id":7}"#,
        )
        .into_token()
        .unwrap();
        assert_eq!(ok.user_id, 7);
        assert_eq!(ok.expires_in, 604800);
        // Lowercase is accepted; Bangumi sends "Bearer".
        assert!(raw(
            r#"{"access_token":"a","refresh_token":"r","expires_in":600,"token_type":"bearer"}"#
        )
        .into_token()
        .is_ok());

        for json in [
            // blank access token
            r#"{"access_token":"  ","refresh_token":"r","expires_in":600,"token_type":"Bearer"}"#,
            // missing refresh token must not silently become ""
            r#"{"access_token":"a","expires_in":600,"token_type":"Bearer"}"#,
            // missing / zero / absurd lifetime
            r#"{"access_token":"a","refresh_token":"r","token_type":"Bearer"}"#,
            r#"{"access_token":"a","refresh_token":"r","expires_in":0,"token_type":"Bearer"}"#,
            r#"{"access_token":"a","refresh_token":"r","expires_in":999999999,"token_type":"Bearer"}"#,
            // wrong or missing token_type
            r#"{"access_token":"a","refresh_token":"r","expires_in":600,"token_type":"mac"}"#,
            r#"{"access_token":"a","refresh_token":"r","expires_in":600}"#,
        ] {
            assert!(raw(json).into_token().is_err(), "{json}");
        }
    }

    #[test]
    fn token_error_body_is_reported_by_code_only() {
        // OAuthToken deliberately has no Debug, so extract the error by match.
        let err = match raw(
            r#"{"error":"invalid_grant","error_description":"code has expired for user xyz"}"#,
        )
        .into_token()
        {
            Ok(_) => panic!("an error payload must not produce a token"),
            Err(error) => error.to_string(),
        };
        assert_eq!(err, "oauth error: invalid_grant");
        assert!(!err.contains("xyz"));
    }

    #[test]
    fn response_bodies_are_never_echoed_in_errors() {
        // A successful HTTP status with a non-JSON body (captive portal HTML).
        let err = parse_oauth_response(reqwest::StatusCode::OK, b"<html>portal</html>")
            .unwrap_err()
            .to_string();
        assert!(!err.contains("portal"), "{err}");
        assert!(err.contains("oauth response invalid JSON"));

        // An error payload on a 200 still reports only the allowlisted code.
        let err = parse_oauth_response(
            reqwest::StatusCode::OK,
            br#"{"error":"invalid_client","error_description":"client abc-secret"}"#,
        )
        .unwrap_err()
        .to_string();
        assert_eq!(err, "oauth error: invalid_client");

        // A non-success status without an error field reports the status only.
        let err = parse_oauth_response(reqwest::StatusCode::BAD_GATEWAY, b"{}")
            .unwrap_err()
            .to_string();
        assert_eq!(err, "oauth request http 502");
    }

    #[test]
    fn token_status_must_match_client_token_and_expiry() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let good = serde_json::json!({
            "access_token": "access",
            "client_id": "app-id",
            "expires": now + 3600,
            "user_id": 42,
        });
        let mut t = token();
        validate_token_status(&good, "app-id", &mut t).unwrap();
        assert_eq!(t.user_id, 42);
        assert!(t.expires_in <= 3600);

        // Wrong client.
        let mut t = token();
        assert!(validate_token_status(&good, "other-id", &mut t).is_err());

        // Token from a different exchange.
        let mut t = token();
        let other = serde_json::json!({
            "access_token": "different",
            "client_id": "app-id",
            "expires": now + 3600,
            "user_id": 42,
        });
        assert!(validate_token_status(&other, "app-id", &mut t).is_err());

        // Already expired / missing identity.
        for bad in [
            serde_json::json!({"access_token":"access","client_id":"app-id","expires":now-1,"user_id":42}),
            serde_json::json!({"access_token":"access","client_id":"app-id","expires":now+3600}),
            serde_json::json!({"access_token":"access","client_id":"app-id","expires":now+3600,"user_id":0}),
        ] {
            let mut t = token();
            assert!(
                validate_token_status(&bad, "app-id", &mut t).is_err(),
                "{bad}"
            );
        }

        // Numeric client id and string user id are tolerated.
        let loose = serde_json::json!({
            "access_token": "access",
            "client_id": 12345,
            "expires": (now + 3600).to_string(),
            "user_id": "42",
        });
        let mut t = token();
        validate_token_status(&loose, "12345", &mut t).unwrap();
        assert_eq!(t.user_id, 42);
    }

    #[test]
    fn collection_pages_fail_loudly_but_empty_account_is_ok() {
        // First page 404 = account has no collections.
        assert!(
            parse_collection_page(reqwest::StatusCode::NOT_FOUND, b"", 0)
                .unwrap()
                .is_none()
        );
        // A 404 after the first page is a real failure, not "no collections".
        assert!(parse_collection_page(reqwest::StatusCode::NOT_FOUND, b"", 50).is_err());

        for status in [
            reqwest::StatusCode::UNAUTHORIZED,
            reqwest::StatusCode::FORBIDDEN,
            reqwest::StatusCode::INTERNAL_SERVER_ERROR,
        ] {
            assert!(parse_collection_page(status, b"{}", 0).is_err(), "{status}");
        }

        // Malformed JSON must not be mistaken for an empty result.
        assert!(parse_collection_page(reqwest::StatusCode::OK, b"not json", 0).is_err());

        // A page that claims a different offset is not usable.
        let shifted = br#"{"data":[],"total":10,"limit":50,"offset":50}"#;
        assert!(parse_collection_page(reqwest::StatusCode::OK, shifted, 0).is_err());

        // An empty page before the reported total means the listing is broken.
        let short = br#"{"data":[],"total":10,"limit":50,"offset":0}"#;
        assert!(parse_collection_page(reqwest::StatusCode::OK, short, 0).is_err());

        // A well-formed final page is accepted.
        let page = br#"{"data":[{"subject_id":1,"type":2}],"total":1,"limit":50,"offset":0}"#;
        let parsed = parse_collection_page(reqwest::StatusCode::OK, page, 0)
            .unwrap()
            .unwrap();
        assert_eq!(parsed.data.len(), 1);
        assert_eq!(parsed.total, 1);
    }
}
