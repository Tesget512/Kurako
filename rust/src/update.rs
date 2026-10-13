//! GitHub update metadata only. No authentication, download or installation.
use anyhow::{bail, Context, Result};
use reqwest::{redirect::Policy, StatusCode, Url};
use serde::Deserialize;
use std::time::Duration;

const LATEST_RELEASE_API: &str = "https://api.github.com/repos/Tesget512/Kurako/releases/latest";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateRelease {
    pub tag_name: String,
    pub html_url: String,
    pub name: String,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    html_url: String,
    name: Option<String>,
    draft: bool,
    prerelease: bool,
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
    }))
}

pub async fn check_update() -> Result<Option<UpdateRelease>> {
    // A fresh client keeps update checks isolated from Bangumi mirror state,
    // cookies, OAuth tokens and cached proxy settings.
    let mut builder = reqwest::Client::builder()
        .user_agent("Kurako-update-check (https://github.com/Tesget512/Kurako)")
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(10))
        .redirect(Policy::none());
    if let Some(proxy) = crate::bangumi::detect_system_proxy() {
        builder = builder.proxy(reqwest::Proxy::all(proxy).context("invalid system proxy")?);
    }
    let response = builder
        .build()
        .context("build update client")?
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
        bail!(
            "GitHub update request returned HTTP {}",
            response.status().as_u16()
        );
    }
    let release = response
        .json::<GithubRelease>()
        .await
        .context("invalid GitHub release response")?;
    stable_release(release)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(draft: bool, prerelease: bool) -> GithubRelease {
        GithubRelease {
            tag_name: "v1.2.3".into(),
            html_url: "https://github.com/Tesget512/Kurako/releases/tag/v1.2.3".into(),
            name: None,
            draft,
            prerelease,
        }
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
}
