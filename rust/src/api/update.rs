pub use crate::update::UpdateRelease;

/// Fetch the latest stable official release. None means no stable release exists.
/// Version comparison belongs to Dart, using PackageInfo's installed version.
pub fn check_update() -> anyhow::Result<Option<UpdateRelease>> {
    super::RT.block_on(crate::update::check_update())
}
