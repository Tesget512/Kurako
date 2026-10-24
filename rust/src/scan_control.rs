use crate::models::ScannedFile;
use once_cell::sync::Lazy;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MatchOutcome {
    Matched,
    NoCandidate,
    RequestFailed,
    PersistFailed,
    NotAttempted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct MatchResult {
    pub(crate) anime_id: i64,
    pub(crate) title: String,
    pub(crate) outcome: MatchOutcome,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub(crate) struct ScanMatchReport {
    pub(crate) matched: Vec<String>,
    pub(crate) unmatched: Vec<String>,
    pub(crate) failed: usize,
    pub(crate) completed_ids: Vec<i64>,
    pub(crate) retry_ids: Vec<i64>,
}

impl ScanMatchReport {
    pub(crate) fn from_results(results: Vec<MatchResult>) -> Self {
        use std::collections::BTreeSet;

        let mut matched = BTreeSet::new();
        let mut unmatched = BTreeSet::new();
        let mut completed_ids = BTreeSet::new();
        let mut retry_ids = BTreeSet::new();
        let mut failed = 0;
        for result in results {
            let title = result.title.trim().to_string();
            if !title.is_empty() {
                match result.outcome {
                    MatchOutcome::Matched => {
                        matched.insert(title);
                    }
                    _ => {
                        unmatched.insert(title);
                    }
                }
            }
            match result.outcome {
                MatchOutcome::Matched | MatchOutcome::NoCandidate => {
                    completed_ids.insert(result.anime_id);
                }
                MatchOutcome::RequestFailed
                | MatchOutcome::PersistFailed
                | MatchOutcome::NotAttempted => {
                    retry_ids.insert(result.anime_id);
                    failed += 1;
                }
            }
        }
        Self {
            matched: matched.into_iter().collect(),
            unmatched: unmatched.into_iter().collect(),
            failed,
            completed_ids: completed_ids.into_iter().collect(),
            retry_ids: retry_ids.into_iter().collect(),
        }
    }

    pub(crate) fn append_to(&self, message: &mut String) {
        use std::fmt::Write;

        if !message.ends_with('\n') {
            message.push('\n');
        }
        let _ = writeln!(
            message,
            "match-result: matched={}|unmatched={}|failed={}",
            self.matched.len(),
            self.unmatched.len(),
            self.failed
        );
        for title in &self.matched {
            let _ = writeln!(message, "matched: {title}");
        }
        for title in &self.unmatched {
            let _ = writeln!(message, "unmatched: {title}");
        }
    }
}

static CHANGED_ANIME_IDS: Lazy<Mutex<HashSet<i64>>> = Lazy::new(|| Mutex::new(HashSet::new()));

static ACTIVE: AtomicBool = AtomicBool::new(false);
static CANCELLED: AtomicBool = AtomicBool::new(false);
static INCREMENTAL: AtomicBool = AtomicBool::new(false);
static CLAIMED_FILE_NAMES: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));

pub fn begin(incremental: bool) -> bool {
    if ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    CLAIMED_FILE_NAMES.lock().unwrap().clear();
    CHANGED_ANIME_IDS.lock().unwrap().clear();
    CANCELLED.store(false, Ordering::Release);
    INCREMENTAL.store(incremental, Ordering::Release);
    true
}

pub fn cancel() {
    if ACTIVE.load(Ordering::Acquire) {
        CANCELLED.store(true, Ordering::Release);
    }
}

pub fn finish() {
    ACTIVE.store(false, Ordering::Release);
    INCREMENTAL.store(false, Ordering::Release);
    CLAIMED_FILE_NAMES.lock().unwrap().clear();
    CHANGED_ANIME_IDS.lock().unwrap().clear();
}

pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

pub fn is_cancelled() -> bool {
    ACTIVE.load(Ordering::Acquire) && CANCELLED.load(Ordering::Acquire)
}

pub fn is_incremental() -> bool {
    ACTIVE.load(Ordering::Acquire) && INCREMENTAL.load(Ordering::Acquire)
}

pub(crate) fn record_changed_anime(ids: impl IntoIterator<Item = i64>) {
    CHANGED_ANIME_IDS.lock().unwrap().extend(ids);
}

/// Candidates for automatic matching this scan.
///
/// A full scan retries everything. An incremental scan normally retries only
/// the titles whose files changed, but a title whose previous attempt could
/// not complete (API down, timeout, circuit breaker) is also retried —
/// otherwise one transient outage would leave it unmatched forever, which
/// looks like the recognizer got worse. A title that was actually searched and
/// found nothing is not retried, which is what keeps incremental scans fast.
pub(crate) fn matching_candidates(
    candidates: Vec<(i64, String)>,
    retry_pending: &HashSet<i64>,
) -> Vec<(i64, String)> {
    if !is_incremental() {
        return candidates;
    }
    let changed = CHANGED_ANIME_IDS.lock().unwrap();
    candidates
        .into_iter()
        .filter(|(id, _)| changed.contains(id) || retry_pending.contains(id))
        .collect()
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
    fn incremental_matching_only_retries_changed_actual_targets() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert!(begin(true));
        record_changed_anime([2]);
        let candidates = vec![(1, "unchanged".into()), (2, "changed".into())];
        assert_eq!(
            matching_candidates(candidates.clone(), &HashSet::new()),
            vec![(2, "changed".into())]
        );
        finish();
        assert!(begin(true));
        assert!(matching_candidates(candidates.clone(), &HashSet::new()).is_empty());
        finish();
        assert!(begin(false));
        assert_eq!(
            matching_candidates(candidates.clone(), &HashSet::new()),
            candidates
        );
        finish();
    }

    #[test]
    fn incremental_matching_also_retries_incomplete_attempts() {
        let _guard = TEST_LOCK.lock().unwrap();
        let candidates = vec![
            (1, "unchanged".into()),
            (2, "changed".into()),
            (3, "failed-earlier".into()),
        ];
        // Id 3 was never matched because the API was unreachable, so it must be
        // retried even though its files are unchanged and id 1 is not.
        let retry_pending: HashSet<i64> = [3].into_iter().collect();
        assert!(begin(true));
        record_changed_anime([2]);
        assert_eq!(
            matching_candidates(candidates.clone(), &retry_pending),
            vec![(2, "changed".into()), (3, "failed-earlier".into())]
        );
        finish();
        // A full scan still retries everything regardless of the flag.
        assert!(begin(false));
        assert_eq!(matching_candidates(candidates, &retry_pending).len(), 3);
        finish();
    }

    #[test]
    fn claims_unicode_equivalent_names_once_ignoring_case() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert!(begin(false));
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
        assert!(begin(true));
        assert!(is_incremental());
        cancel();
        assert!(is_cancelled());
        finish();
    }

    #[test]
    fn duplicate_names_inside_one_folder_survive_but_lower_folder_loses() {
        let _guard = TEST_LOCK.lock().unwrap();
        finish();
        assert!(begin(false));
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
        assert!(begin(false));
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
