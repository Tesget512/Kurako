//! Local Anubis verification bridge. Never accepts or returns account tokens.
use anyhow::Result;

pub fn configure_bangumi_mirror_verification(
    api_cookie: String,
    image_cookie: String,
    user_agent: String,
) -> Result<()> {
    crate::bangumi::configure_mirror_verification(api_cookie, image_cookie, user_agent)
}

/// Forced mirror probe, even while the user's preference remains disabled.
/// Returns the exact mirror image URL to verify separately in its WebView host.
pub async fn probe_bangumi_mirror() -> Result<String> {
    crate::bangumi::probe_mirror().await
}

pub async fn probe_bangumi_mirror_image(image_url: String) -> Result<()> {
    crate::bangumi::probe_mirror_image(image_url).await
}

pub fn clear_bangumi_mirror_verification() {
    crate::bangumi::clear_mirror_verification();
}
