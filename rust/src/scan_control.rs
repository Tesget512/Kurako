use crate::models::ScannedFile;
use once_cell::sync::Lazy;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use unicode_normalization::UnicodeNormalization;

static ACTIVE: AtomicBool = AtomicBool::new(false);
static CANCELLED: AtomicBool = AtomicBool::new(false);
static CLAIMED_FILE_NAMES: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));

pub fn begin() -> bool {
    if ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    CLAIMED_FILE_NAMES.lock().unwrap().clear();
    CANCELLED.store(false, Ordering::Release);
    true
}

pub fn cancel() {
    if ACTIVE.load(Ordering::Acquire) {
        CANCELLED.store(true, Ordering::Release);
    }
}

pub fn finish() {
    ACTIVE.store(false, Ordering::Release);
    CLAIMED_FILE_NAMES.lock().unwrap().clear();
}

pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

pub fn is_cancelled() -> bool {
    ACTIVE.load(Ordering::Acquire) && CANCELLED.load(Ordering::Acquire)
}

pub fn normalized_file_name(file_name: &str) -> String {
    file_name.nfc().flat_map(char::to_lowercase).collect()
}

pub fn claim_file_name(file_name: &str) -> bool {
    if !is_active() {
        return true;
    }
    CLAIMED_FILE_NAMES
        .lock()
        .unwrap()
        .insert(normalized_file_name(file_name))
}

pub fn claim_files(files: Vec<ScannedFile>) -> (Vec<ScannedFile>, usize) {
    let original_len = files.len();
    let mut claimed = CLAIMED_FILE_NAMES.lock().unwrap();
    let batch_names = files
        .iter()
        .map(|file| normalized_file_name(&file.file_name))
        .collect::<HashSet<_>>();
    // Duplicate names inside one selected library folder share the same
    // priority and are retained. Only names claimed by an earlier folder are
    // filtered out.
    let kept = files
        .into_iter()
        .filter(|file| !claimed.contains(&normalized_file_name(&file.file_name)))
        .collect::<Vec<_>>();
    claimed.extend(batch_names);
    let skipped = original_len.saturating_sub(kept.len());
    (kept, skipped)
}

/// Reconcile already-indexed rows from one unchanged or temporarily offline
/// folder. Duplicate filenames inside this folder stay together; only names
/// reserved by an earlier, higher-priority folder are returned for deletion.
pub fn claim_existing_entries(entries: &[(String, String)]) -> Vec<String> {
    let mut claimed = CLAIMED_FILE_NAMES.lock().unwrap();
    let batch_names = entries
        .iter()
        .map(|(_, name)| normalized_file_name(name))
        .collect::<HashSet<_>>();
    let conflicts = batch_names
        .iter()
        .filter(|name| claimed.contains(*name))
        .cloned()
        .collect::<HashSet<_>>();
    let paths = entries
        .iter()
        .filter(|(_, name)| conflicts.contains(&normalized_file_name(name)))
        .map(|(path, _)| path.clone())
        .collect();
    claimed.extend(batch_names);
    paths
}

pub async fn wait_cancelled() {
    while !is_cancelled() {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

    fn file(uri: &str, name: &str) -> ScannedFile {
        ScannedFile {
            uri: uri.to_string(),
            file_name: name.to_string(),
            file_size: 100,
            relative_parent: String::new(),
        }
    }

    #[test]
    fn claims_unicode_equivalent_names_once_ignoring_case() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert!(begin());
        assert!(claim_file_name("Azu\u{0308}manga 01.MKV"));
        assert!(!claim_file_name("Azümanga 01.mkv"));
        finish();
    }

    #[test]
    fn cancellation_only_applies_to_active_session() {
        let _guard = TEST_LOCK.lock().unwrap();
        finish();
        cancel();
        assert!(!is_cancelled());
        assert!(begin());
        cancel();
        assert!(is_cancelled());
        finish();
    }

    #[test]
    fn duplicate_names_inside_one_folder_survive_but_lower_folder_loses() {
        let _guard = TEST_LOCK.lock().unwrap();
        finish();
        assert!(begin());
        let (first, skipped) = claim_files(vec![
            file("/A/show/01.mkv", "01.mkv"),
            file("/A/other/01.mkv", "01.mkv"),
        ]);
        assert_eq!(first.len(), 2);
        assert_eq!(skipped, 0);
        let (second, skipped) = claim_files(vec![
            file("smb://server/Anime/01.mkv", "01.MKV"),
            file("smb://server/Anime/02.mkv", "02.mkv"),
        ]);
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].file_name, "02.mkv");
        assert_eq!(skipped, 1);
        finish();
    }

    #[test]
    fn existing_lower_priority_conflicts_return_their_paths() {
        let _guard = TEST_LOCK.lock().unwrap();
        finish();
        assert!(begin());
        claim_file_name("Episode 01.mkv");
        let conflicts = claim_existing_entries(&[
            (
                "smb://server/01.mkv".to_string(),
                "episode 01.MKV".to_string(),
            ),
            (
                "smb://server/02.mkv".to_string(),
                "Episode 02.mkv".to_string(),
            ),
        ]);
        assert_eq!(conflicts, vec!["smb://server/01.mkv"]);
        finish();
    }
}
