pub use crate::update::{UpdateAsset, UpdateRelease};

/// Fetch the latest stable official release. None means no stable release exists.
/// Version comparison and asset selection belong to Dart, using PackageInfo's
/// installed version and the running platform/ABI.
pub fn check_update() -> anyhow::Result<Option<UpdateRelease>> {
    super::RT.block_on(crate::update::check_update())
}
