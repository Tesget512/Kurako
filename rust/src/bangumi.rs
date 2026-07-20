use crate::models::BangumiSubject;
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use serde::Deserialize;
use std::sync::Mutex;

const BASE: &str = "https://api.bgm.tv";
const OAUTH_BASE: &str = "https://bgm.tv/oauth";
const USER_AGENT: &str = "animebdplayer/1.0 (https://github.com/animebd/anime-bd-player)";

// Bangumi OAuth application credentials. The real values live in the
// git-ignored `secrets.rs` (copy `secrets.rs.example` → `secrets.rs`). A desktop
// app is a "public client" — the secret can't be truly confidential in a
// distributed binary — but keeping it out of the public repo avoids scraping
// and lets forks use their own app.
#[path = "secrets.rs"]
mod secrets;
pub use secrets::{OAUTH_CLIENT_ID, OAUTH_CLIENT_SECRET};
/// Must match the "回调地址" registered on the developer console.
pub const OAUTH_REDIRECT_URI: &str = "http://localhost:6420/callback";

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
        || auth(client.get(format!("{BASE}/v0/me"))),
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

/// Download raw bytes from a URL through the proxied client (for cover images).
pub async fn fetch_bytes(url: &str) -> Result<Vec<u8>> {
    let resp = client()?.get(url).send().await.context("fetch bytes")?;
    if !resp.status().is_success() {
        anyhow::bail!("fetch {url} -> {}", resp.status());
    }
    Ok(resp.bytes().await?.to_vec())
}

fn client() -> Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30));

    // Bangumi (api.bgm.tv / lain.bgm.tv) is frequently DNS-poisoned in mainland
    // China, so a direct connection times out. Auto-detect the system HTTP proxy
    // (e.g. clash/v2rayN at 127.0.0.1:7890) and route requests through it.
    if let Some(proxy_url) = detect_system_proxy() {
        if let Ok(p) = reqwest::Proxy::all(&proxy_url) {
            builder = builder.proxy(p);
        }
    }

    builder.build().context("build http client")
}

/// Detect a system HTTP proxy: env vars first, then (on Windows) the per-user
/// Internet Settings registry key that clash/v2rayN/etc. configure.
pub fn detect_system_proxy() -> Option<String> {
    for var in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
        if let Ok(val) = std::env::var(var) {
            let v = val.trim();
            if !v.is_empty() {
                return Some(normalize_proxy(v));
            }
        }
    }
    #[cfg(windows)]
    {
        if let Some(p) = read_windows_proxy() {
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
}

#[derive(Deserialize)]
struct RawTag {
    #[serde(default)]
    name: String,
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
        BangumiSubject {
            id: r.id,
            name: r.name,
            name_cn: r.name_cn,
            summary: r.summary,
            cover_url: r.images.and_then(|i| i.best()),
            air_date: r.date,
            eps: r.eps,
            rating: r.rating.and_then(|x| x.score).filter(|s| *s > 0.0),
            tags: r
                .tags
                .unwrap_or_default()
                .into_iter()
                .map(|t| t.name)
                .filter(|n| !n.is_empty())
                .take(10)
                .collect(),
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
        let resp = mk().send().await.with_context(|| format!("{what} request"))?;
        if resp.status().as_u16() != 429 {
            return Ok(resp);
        }
        tokio::time::sleep(std::time::Duration::from_millis(900 * (attempt + 1))).await;
    }
    anyhow::bail!("{what}: rate limited (429) after retries");
}

/// Search anime subjects (type=2) by keyword, sorted by relevance.
pub async fn search(keyword: &str, limit: u32) -> Result<Vec<BangumiSubject>> {
    let url = format!("{BASE}/v0/search/subjects?limit={limit}");
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
    let url = format!("{BASE}/search/subject/{encoded}?type=2&max_results={limit}&responseGroup=small");
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
            tags: Vec::new(),
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
        .map(|c| if "&,:~-_!！？?・/".contains(c) { ' ' } else { c })
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
        let coverage =
            (normalize_for_match(kw).chars().count() as f64 / t_len as f64).min(1.0);
        // v0 search first. IMPORTANT: only fall back to the legacy fuzzy
        // endpoint when v0 *successfully* returned nothing — a transient v0
        // error (rate limit) must NOT reroute to the much looser legacy
        // matcher at full trust, that's how "Bocchi the Rock!" once matched a
        // GoBots movie. Retry the error once instead.
        let mut hits = Vec::new();
        let mut v0_confirmed_empty = false;
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
                Err(_) if attempt == 0 => {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                Err(_) => {}
            }
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
    let title_toks: std::collections::HashSet<String> =
        latin_tokens(raw_title).into_iter().map(|t| t.to_lowercase()).collect();
    let mut extra: f64 = 0.0;
    let mut cand_distinctive: std::collections::HashSet<String> = std::collections::HashSet::new();
    for t in latin_tokens(&cand.name).into_iter().chain(latin_tokens(&cand.name_cn)) {
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
    let title_cjk: std::collections::HashSet<char> =
        norm_title.chars().filter(|c| (*c as u32) > 0x2E7F).collect();
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
        regex::Regex::new(r"(?i)(?:season\s*(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)\s*season|\bS(\d{2})\b)")
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
    let (short, long) = if ab.len() <= bb.len() { (&ab, &bb) } else { (&bb, &ab) };
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
    let url = format!("{BASE}/v0/subjects/{id}");
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
pub fn authorize_url(client_id: &str, redirect_uri: &str) -> String {
    format!(
        "{OAUTH_BASE}/authorize?client_id={}&response_type=code&redirect_uri={}",
        urlencode(client_id),
        urlencode(redirect_uri),
    )
}

/// The token payload returned by the OAuth token endpoint. Field names match
/// Bangumi's JSON so it deserializes directly.
#[derive(Debug, Clone, Deserialize)]
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
    error_description: Option<String>,
}

impl RawOAuthToken {
    fn into_token(self) -> Result<OAuthToken> {
        if let Some(err) = self.error {
            let desc = self.error_description.unwrap_or_default();
            anyhow::bail!("oauth error: {err} {desc}");
        }
        let user_id = match self.user_id {
            serde_json::Value::Number(n) => n.as_i64().unwrap_or(0),
            serde_json::Value::String(s) => s.parse().unwrap_or(0),
            _ => 0,
        };
        Ok(OAuthToken {
            access_token: self
                .access_token
                .context("oauth response missing access_token")?,
            refresh_token: self.refresh_token.unwrap_or_default(),
            expires_in: self.expires_in.unwrap_or(0),
            user_id,
        })
    }
}

/// Exchange an authorization `code` for an access + refresh token.
pub async fn exchange_code(
    client_id: &str,
    client_secret: &str,
    code: &str,
    redirect_uri: &str,
) -> Result<OAuthToken> {
    let params = [
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("code", code),
        ("redirect_uri", redirect_uri),
    ];
    post_token(&params).await
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
    let resp = client()?
        .post(format!("{OAUTH_BASE}/access_token"))
        .form(params)
        .send()
        .await
        .context("oauth token request")?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let raw: RawOAuthToken = serde_json::from_str(&body)
        .with_context(|| format!("parse oauth token response (http {status}): {body}"))?;
    raw.into_token()
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
            "{BASE}/v0/users/{username}/collections?subject_type=2&limit={limit}&offset={offset}"
        );
        let resp = send_with_backoff(|| auth(client.get(&url)), "bangumi all_collections").await?;
        if !resp.status().is_success() {
            // 404 = no collections
            break;
        }
        let page: CollectionPage = match resp.json().await {
            Ok(p) => p,
            Err(_) => break,
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
    let url = format!("{BASE}/v0/users/{username}/collections/{subject_id}");
    let client = client()?;
    let resp = send_with_backoff(|| auth(client.get(&url)), "bangumi collection").await?;
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
    let url = format!("{BASE}/v0/users/-/collections/{subject_id}");
    let body = serde_json::json!({ "type": collection_type });
    let client = client()?;
    let resp = send_with_backoff(
        || auth(client.post(&url).json(&body)),
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
    let url = format!("{BASE}/v0/subjects/{subject_id}/episodes?type=0&limit={limit}");
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

    fn subj(id: i64, name: &str, cn: &str) -> BangumiSubject {
        BangumiSubject { id, name: name.into(), name_cn: cn.into(), summary: String::new(), cover_url: None, air_date: None, eps: None, rating: None, tags: Vec::new() }
    }

    #[test]
    fn variants_generated() {
        let v = keyword_variants("Hina Logi from Luck & Logic");
        assert!(v.iter().any(|s| s == "Hina Logi from Luck & Logic"));
        assert!(v.iter().any(|s| s.eq_ignore_ascii_case("Hina Logi")));
        assert!(v.iter().any(|s| s.eq_ignore_ascii_case("Luck Logic")));
    }

    const V0: f64 = 0.55; // full-title v0 hit-0 prior

    #[test]
    fn scores_correct_candidate_higher() {
        let raw = "Hina Logi from Luck & Logic";
        let title = normalize_for_match(raw);
        let correct = subj(175362, "ひなろじ 〜from Luck & Logic〜", "雏逻辑 〜from Luck & Logic〜");
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
        let correct = subj(376703, "アイドルマスター シンデレラガールズ U149", "偶像大师 灰姑娘 U149");
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
        let junk1b = subj(303126, "劇場版 異世界かるてっと ～あなざーわーるど～", "剧场版 异世界四重奏 ～Another World～");
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
        let correct = subj(376703, "アイドルマスター シンデレラガールズ U149", "偶像大师 灰姑娘 U149");
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
        let s3 = subj(425998, "Re:ゼロから始める異世界生活 3rd season 襲擊編", "Re：从零开始的异世界生活 第三季 袭击篇");
        let base = subj(140001, "Re:ゼロから始める異世界生活", "Re：从零开始的异世界生活");
        let s4 = subj(547888, "Re:ゼロから始める異世界生活 4th season", "Re：从零开始的异世界生活 第四季 丧失篇");
        let sc3 = score_candidate(&title, raw, &s3, 1.0, V0, 0);
        let scb = score_candidate(&title, raw, &base, 1.0, V0, 3);
        let sc4 = score_candidate(&title, raw, &s4, 1.0, V0, 4);
        assert!(sc3 < 0.38, "wrong season must be rejected, got {sc3}");
        assert!(scb < 0.38, "base entry must not absorb explicit S4, got {scb}");
        assert!(sc4 > sc3 && sc4 > scb, "matching season must win: s4={sc4} s3={sc3} base={scb}");
    }

    #[test]
    fn season_markers_parsed() {
        assert_eq!(season_marker("Foo Season 4"), Some(4));
        assert_eq!(season_marker("Foo 3rd season Bar"), Some(3));
        assert_eq!(season_marker("Re：从零开始的异世界生活 第三季 袭击篇"), Some(3));
        assert_eq!(season_marker("Re：从零开始的异世界生活 第四季 丧失篇"), Some(4));
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
