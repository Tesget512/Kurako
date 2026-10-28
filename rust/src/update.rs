//! GitHub release metadata for the in-app update check. Assets are described
//! (name, size, URL, digest) so the Dart layer can pick and verify a download;
//! no download, authentication or installation happens here.
use anyhow::{bail, Context, Result};
use reqwest::{redirect::Policy, StatusCode, Url};
use serde::Deserialize;
use std::time::Duration;

const LATEST_RELEASE_API: &str = "https://api.github.com/repos/Tesget512/Kurako/releases/latest";
/// Non-API fallback. Anonymous API calls are capped at 60/hour per IP, which a
/// shared proxy exit address exhausts quickly; these pages are ordinary web
/// traffic and are not counted against that quota.
const LATEST_RELEASE_PAGE: &str = "https://github.com/Tesget512/Kurako/releases/latest";
const EXPANDED_ASSETS_PREFIX: &str =
    "https://github.com/Tesget512/Kurako/releases/expanded_assets/";

/// One downloadable file attached to a release. GitHub supplies a
/// `sha256:<hex>` digest for uploaded assets, which the downloader checks.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct UpdateAsset {
    pub name: String,
    #[serde(default)]
    pub size: u64,
    pub browser_download_url: String,
    #[serde(default)]
    pub digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateRelease {
    pub tag_name: String,
    pub html_url: String,
    pub name: String,
    pub notes: Option<String>,
    pub assets: Vec<UpdateAsset>,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    html_url: String,
    name: Option<String>,
    #[serde(default)]
    body: Option<String>,
    draft: bool,
    prerelease: bool,
    #[serde(default)]
    assets: Vec<UpdateAsset>,
}

/// Only allow the project's HTTPS release pages, never a download URL.
pub fn is_project_release_url(value: &str) -> bool {
    let Ok(url) = Url::parse(value) else {
        return false;
    };
    let prefix = "https://github.com/Tesget512/Kurako/releases/tag/";
    // Check the raw authority as well: Url normalizes an explicit :443 away.
    if !value.starts_with(prefix) || value.len() == prefix.len() {
        return false;
    }
    let raw_tag = &value[prefix.len()..];
    if raw_tag.contains('/')
        || raw_tag.contains('\\')
        || raw_tag.to_ascii_lowercase().contains("%2f")
        || raw_tag.to_ascii_lowercase().contains("%5c")
    {
        return false;
    }
    url.scheme() == "https"
        && url.host_str() == Some("github.com")
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && url.path().starts_with("/Tesget512/Kurako/releases/tag/")
        && !url.path().ends_with('/')
        && url.path_segments().is_some_and(|segments| {
            let parts: Vec<_> = segments.collect();
            parts.len() == 5 && !parts[4].is_empty() && parts[4] != "." && parts[4] != ".."
        })
}

fn stable_release(release: GithubRelease) -> Result<Option<UpdateRelease>> {
    if release.draft || release.prerelease {
        return Ok(None);
    }
    if release.tag_name.trim().is_empty() || !is_project_release_url(&release.html_url) {
        bail!("GitHub returned invalid release metadata");
    }
    Ok(Some(UpdateRelease {
        name: release.name.unwrap_or_else(|| release.tag_name.clone()),
        tag_name: release.tag_name,
        html_url: release.html_url,
        assets: release.assets,
        notes: release.body.filter(|body| !body.trim().is_empty()),
    }))
}

pub async fn check_update() -> Result<Option<UpdateRelease>> {
    let client = update_client()?;
    match check_update_via_api(&client).await {
        Ok(release) => Ok(release),
        // The API is rate limited or otherwise unavailable; the public release
        // pages carry the same tag and asset names without touching that quota.
        Err(api_error) => match check_update_via_pages(&client).await {
            Ok(release) => Ok(release),
            Err(_) => Err(api_error),
        },
    }
}

fn update_client() -> Result<reqwest::Client> {
    // A fresh client keeps update checks isolated from Bangumi mirror state,
    // cookies, OAuth tokens and cached proxy settings.
    let mut builder = reqwest::Client::builder()
        .user_agent("Kurako-update-check (https://github.com/Tesget512/Kurako)")
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(10))
        .redirect(Policy::none());
    builder = crate::tls::configure(builder);
    if let Some(proxy) = crate::bangumi::detect_system_proxy() {
        builder = builder.proxy(reqwest::Proxy::all(proxy).context("invalid system proxy")?);
    }
    builder.build().context("build update client")
}

async fn check_update_via_api(client: &reqwest::Client) -> Result<Option<UpdateRelease>> {
    let mut response = client
        .get(LATEST_RELEASE_API)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .context("GitHub update request failed")?;
    if response.status() == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !response.status().is_success() {
        // Do not expose response bodies, proxy addresses or environment values.
        if is_rate_limited(&response) {
            bail!("GitHub update request was rate limited");
        }
        bail!(
            "GitHub update request returned HTTP {}",
            response.status().as_u16()
        );
    }
    let body = read_bounded_body(&mut response).await?;
    let release = serde_json::from_slice::<GithubRelease>(&body)
        .context("invalid GitHub release response")?;
    stable_release(release)
}

/// Anonymous API quota exhausted: GitHub answers 403 and reports zero remaining.
fn is_rate_limited(response: &reqwest::Response) -> bool {
    let remaining = response
        .headers()
        .get("x-ratelimit-remaining")
        .and_then(|value| value.to_str().ok());
    is_rate_limit_status(response.status(), remaining)
}

fn is_rate_limit_status(status: StatusCode, remaining: Option<&str>) -> bool {
    status == StatusCode::FORBIDDEN && remaining.map(str::trim) == Some("0")
}

async fn read_bounded_body(response: &mut reqwest::Response) -> Result<Vec<u8>> {
    // The release payload is a few KB; bound it so a hijacked or misbehaving
    // endpoint cannot stream an unbounded body into memory.
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .context("GitHub update request failed")?
    {
        if body.len().saturating_add(chunk.len()) > 512 * 1024 {
            bail!("GitHub update response too large");
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Resolve the latest stable tag from the `/releases/latest` redirect.
///
/// The shared client disables redirects (the API must never be followed
/// elsewhere), so the 302 is read here and the target is validated before a
/// second request fetches it.
async fn check_update_via_pages(client: &reqwest::Client) -> Result<Option<UpdateRelease>> {
    let response = client
        .get(LATEST_RELEASE_PAGE)
        .send()
        .await
        .context("GitHub release page request failed")?;
    let status = response.status();
    if status == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    let location = response
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.to_string());
    let tag = if status.is_redirection() {
        location
            .as_deref()
            .and_then(|value| Url::parse(value).ok())
            .and_then(|url| tag_from_latest_redirect(url.as_str()))
    } else if status.is_success() {
        // Some intermediaries follow the redirect themselves.
        tag_from_latest_redirect(response.url().as_str())
    } else {
        None
    };
    let Some(tag) = tag else {
        bail!(
            "GitHub release page returned HTTP {} without a stable tag",
            status.as_u16()
        );
    };
    let html_url = format!("https://github.com/Tesget512/Kurako/releases/tag/{tag}");
    if !is_project_release_url(&html_url) {
        bail!("GitHub returned invalid release metadata");
    }
    let assets = fetch_expanded_assets(client, &tag)
        .await
        .unwrap_or_default();
    Ok(Some(UpdateRelease {
        name: tag.clone(),
        tag_name: tag,
        html_url,
        assets,
        notes: None,
    }))
}

/// `/releases/latest` redirects to `/releases/tag/<tag>`. Anything else (a
/// login page, an error page, an unexpected host) yields no tag.
fn tag_from_latest_redirect(url: &str) -> Option<String> {
    let url = Url::parse(url).ok()?;
    if url.scheme() != "https" || url.host_str() != Some("github.com") {
        return None;
    }
    let segments: Vec<_> = url.path_segments()?.collect();
    if segments.len() != 5
        || segments[0] != "Tesget512"
        || segments[1] != "Kurako"
        || segments[2] != "releases"
        || segments[3] != "tag"
    {
        return None;
    }
    let tag = segments[4];
    if tag.is_empty() || tag == "." || tag == ".." {
        return None;
    }
    Some(tag.to_string())
}

async fn fetch_expanded_assets(client: &reqwest::Client, tag: &str) -> Result<Vec<UpdateAsset>> {
    let url = format!("{EXPANDED_ASSETS_PREFIX}{tag}");
    let mut response = client
        .get(&url)
        .send()
        .await
        .context("GitHub asset list request failed")?;
    if !response.status().is_success() {
        bail!(
            "GitHub asset list returned HTTP {}",
            response.status().as_u16()
        );
    }
    let body = read_bounded_body(&mut response).await?;
    Ok(parse_expanded_assets(&String::from_utf8_lossy(&body), tag))
}

/// The expanded-assets fragment lists one anchor per file. Sizes are optional
/// (they may be rendered client-side), so an unknown size stays 0 and the
/// downloader falls back to the streamed byte count.
fn parse_expanded_assets(html: &str, tag: &str) -> Vec<UpdateAsset> {
    let prefix = format!("/Tesget512/Kurako/releases/download/{tag}/");
    let mut assets = Vec::new();
    for fragment in html.split("href=\"").skip(1) {
        let Some(end) = fragment.find('"') else {
            continue;
        };
        let href = &fragment[..end];
        let Some(name) = href.strip_prefix(&prefix) else {
            continue;
        };
        if name.is_empty() || name.contains('/') || name.contains('\\') {
            continue;
        }
        if assets.iter().any(|asset: &UpdateAsset| asset.name == name) {
            continue;
        }
        assets.push(UpdateAsset {
            name: name.to_string(),
            size: 0,
            browser_download_url: format!("https://github.com{href}"),
            digest: None,
        });
    }
    assets
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(draft: bool, prerelease: bool) -> GithubRelease {
        GithubRelease {
            tag_name: "v1.2.3".into(),
            html_url: "https://github.com/Tesget512/Kurako/releases/tag/v1.2.3".into(),
            name: None,
            body: None,
            draft,
            prerelease,
            assets: Vec::new(),
        }
    }

    #[test]
    fn release_notes_survive_the_api_contract() {
        let json = r###"{"tag_name":"v1.2.3","html_url":"https://github.com/Tesget512/Kurako/releases/tag/v1.2.3","draft":false,"prerelease":false,"body":"## Changes\n- Improved layout"}"###;
        let result = stable_release(serde_json::from_str(json).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(
            result.notes.as_deref(),
            Some("## Changes\n- Improved layout")
        );
    }

    #[test]
    fn assets_are_carried_through_with_optional_fields() {
        let mut with_assets = release(false, false);
        with_assets.assets = vec![
            UpdateAsset {
                name: "Kurako-Android-arm64-v8a-1.2.3-release.apk".into(),
                size: 60_000_000,
                browser_download_url:
                    "https://github.com/Tesget512/Kurako/releases/download/v1.2.3/Kurako-Android-arm64-v8a-1.2.3-release.apk"
                        .into(),
                digest: Some(format!("sha256:{}", "a".repeat(64))),
            },
            // Older releases predate GitHub's digest field.
            UpdateAsset {
                name: "Kurako-Windows-x64-1.2.3-release.zip".into(),
                size: 55_000_000,
                browser_download_url:
                    "https://github.com/Tesget512/Kurako/releases/download/v1.2.3/Kurako-Windows-x64-1.2.3-release.zip"
                        .into(),
                digest: None,
            },
        ];
        let parsed = stable_release(with_assets).unwrap().unwrap();
        assert_eq!(parsed.assets.len(), 2);
        assert_eq!(parsed.assets[0].size, 60_000_000);
        assert!(parsed.assets[0].digest.is_some());
        assert!(parsed.assets[1].digest.is_none());
    }

    #[test]
    fn assets_default_to_empty_when_the_field_is_absent() {
        let json = r#"{"tag_name":"v1.2.3",
            "html_url":"https://github.com/Tesget512/Kurako/releases/tag/v1.2.3",
            "draft":false,"prerelease":false}"#;
        let parsed: GithubRelease = serde_json::from_str(json).unwrap();
        let release = stable_release(parsed).unwrap().unwrap();
        assert!(release.assets.is_empty());
    }

    #[test]
    fn validates_project_release_urls() {
        assert!(is_project_release_url(&release(false, false).html_url));
        for url in [
            "http://github.com/Tesget512/Kurako/releases/tag/v1",
            "https://github.com:443/Tesget512/Kurako/releases/tag/v1",
            "https://user@github.com/Tesget512/Kurako/releases/tag/v1",
            "https://github.com.evil.test/Tesget512/Kurako/releases/tag/v1",
            "https://github.com/other/Kurako/releases/tag/v1",
            "https://github.com/Tesget512/Kurako/releases/download/v1/a.apk",
            "https://github.com/Tesget512/Kurako/releases/tag/",
            "https://github.com/Tesget512/Kurako/releases/tag/v1?x=1",
            "https://github.com/Tesget512/Kurako/releases/tag/v1#x",
            "https://github.com/Tesget512/Kurako/releases/tag/v1/../../other",
            "https://github.com/Tesget512/Kurako/releases/tag/v1/../other",
            "https://github.com/Tesget512/Kurako/releases/tag/a%2fb",
            "https://github.com/Tesget512/Kurako/releases/tag/a%5Cb",
        ] {
            assert!(!is_project_release_url(url), "{url}");
        }
    }

    #[test]
    fn ignores_drafts_and_prereleases() {
        assert_eq!(stable_release(release(true, false)).unwrap(), None);
        assert_eq!(stable_release(release(false, true)).unwrap(), None);
        assert_eq!(
            stable_release(release(false, false)).unwrap().unwrap().name,
            "v1.2.3"
        );
    }

    #[test]
    fn rejects_invalid_metadata() {
        let mut invalid = release(false, false);
        invalid.tag_name.clear();
        assert!(stable_release(invalid).is_err());
        let mut invalid = release(false, false);
        invalid.html_url = "https://example.com".into();
        assert!(stable_release(invalid).is_err());
    }

    #[test]
    fn latest_redirect_yields_only_a_stable_tag() {
        assert_eq!(
            tag_from_latest_redirect("https://github.com/Tesget512/Kurako/releases/tag/v1.0.2"),
            Some("v1.0.2".to_string())
        );
        for url in [
            "https://github.com/Tesget512/Kurako/releases/latest",
            "https://github.com/Tesget512/Kurako/releases/tag/",
            "https://github.com/Tesget512/Other/releases/tag/v1",
            "https://github.com.evil.test/Tesget512/Kurako/releases/tag/v1",
            "http://github.com/Tesget512/Kurako/releases/tag/v1",
            "https://github.com/login?return_to=%2FTesget512%2FKurako",
        ] {
            assert_eq!(tag_from_latest_redirect(url), None, "{url}");
        }
    }

    #[test]
    fn expanded_assets_extract_names_and_download_urls() {
        let html = r#"
            <a href="/Tesget512/Kurako/releases/download/v1.0.2/Kurako-macOS-1.0.2-universal-adhoc-release.dmg" rel="nofollow">x</a>
            <a href="/Tesget512/Kurako/releases/download/v1.0.2/Kurako-Android-arm64-v8a-1.0.2-release.apk">y</a>
            <a href="/Tesget512/Kurako/releases/download/v1.0.2/Kurako-Android-arm64-v8a-1.0.2-release.apk">dup</a>
            <a href="/Tesget512/Kurako/releases/download/v9.9.9/Kurako-other.dmg">wrong tag</a>
            <a href="/Tesget512/Kurako/releases/download/v1.0.2/../escape.dmg">traversal</a>
            <a href="/Tesget512/Kurako/archive/v1.0.2.tar.gz">archive</a>
        "#;
        let assets = parse_expanded_assets(html, "v1.0.2");
        assert_eq!(assets.len(), 2, "{assets:?}");
        assert_eq!(
            assets[0].browser_download_url,
            "https://github.com/Tesget512/Kurako/releases/download/v1.0.2/Kurako-macOS-1.0.2-universal-adhoc-release.dmg"
        );
        // Unknown size is 0 so the downloader can fall back to streamed bytes.
        assert_eq!(assets[0].size, 0);
        assert!(assets[0].digest.is_none());
    }

    #[test]
    fn rate_limit_is_detected_from_headers_only() {
        // Header parsing is exercised by constructing the status/header pair
        // through a tiny helper rather than a live response.
        assert!(is_rate_limit_status(StatusCode::FORBIDDEN, Some("0")));
        assert!(!is_rate_limit_status(StatusCode::FORBIDDEN, Some("12")));
        assert!(!is_rate_limit_status(StatusCode::FORBIDDEN, None));
        assert!(!is_rate_limit_status(StatusCode::OK, Some("0")));
    }
}
