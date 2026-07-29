//! Read-only, report-only candidate duplicate checker.
//!
//! This module deliberately has no dependency on the library scan session and
//! never mutates the database. The public API layer supplies a snapshot of the
//! current episodes, then converts the internal events/results into FRB models.

use crate::models::{DuplicateCandidateGroup, DuplicateCheckItem};
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use percent_encoding::percent_decode_str;
use reqwest::Url;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::SystemTime;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::watch;

const BLOCK_SIZE: u64 = 128 * 1024;
const FULL_READ_LIMIT: u64 = BLOCK_SIZE * 4;
const HASH_DOMAIN: &[u8] = b"Kurako sparse duplicate fingerprint v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateCheckFailure {
    pub episode_id: i64,
    pub file_name: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateCheckReport {
    pub groups: Vec<DuplicateCandidateGroup>,
    pub failures: Vec<DuplicateCheckFailure>,
    pub checked: i64,
    pub total: i64,
    pub cancelled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DuplicateCheckEvent {
    Progress {
        current: i64,
        total: i64,
        message: String,
    },
    Warning(DuplicateCheckFailure),
    Group(DuplicateCandidateGroup),
    Done {
        checked: i64,
        total: i64,
        cancelled: bool,
    },
}

struct Session {
    token: u64,
    cancellation: watch::Sender<bool>,
    running: bool,
}

static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);
static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));

/// Reserve one independent duplicate-check session. Only one checker may read
/// the media sources at once; it never changes or cancels the scan session.
pub fn begin() -> Result<u64> {
    if crate::scan_control::is_active() {
        anyhow::bail!("请先结束正在进行的媒体库扫描");
    }
    if crate::smb::maintenance_read_is_busy() || crate::webdav::maintenance_read_is_busy() {
        anyhow::bail!("请先结束正在进行的网络播放或下载");
    }
    begin_session()
}

fn begin_session() -> Result<u64> {
    let mut session = SESSION.lock().unwrap();
    if session.is_some() {
        anyhow::bail!("已有疑似重复检查正在运行");
    }
    let token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
    let (cancellation, _) = watch::channel(false);
    *session = Some(Session {
        token,
        cancellation,
        running: false,
    });
    Ok(token)
}

/// Cancel only the matching generation. A late cancel from a disposed page can
/// never cancel a newer run.
pub fn cancel(token: u64) {
    let mut session = SESSION.lock().unwrap();
    let Some(active) = session.as_ref() else {
        return;
    };
    if active.token != token {
        return;
    }
    let _ = active.cancellation.send(true);
    if !active.running {
        *session = None;
    }
}

fn start(token: u64) -> Result<watch::Receiver<bool>> {
    let mut session = SESSION.lock().unwrap();
    let active = session
        .as_mut()
        .filter(|active| active.token == token)
        .context("疑似重复检查会话已失效")?;
    if active.running {
        anyhow::bail!("疑似重复检查会话已经开始");
    }
    active.running = true;
    Ok(active.cancellation.subscribe())
}

fn finish(token: u64) {
    let mut session = SESSION.lock().unwrap();
    if session.as_ref().is_some_and(|active| active.token == token) {
        *session = None;
    }
}

struct SessionGuard(u64);

impl Drop for SessionGuard {
    fn drop(&mut self) {
        finish(self.0);
    }
}

fn cancelled(cancellation: &watch::Receiver<bool>) -> bool {
    *cancellation.borrow()
}

async fn wait_cancelled(cancellation: &mut watch::Receiver<bool>) {
    if *cancellation.borrow() {
        return;
    }
    while cancellation.changed().await.is_ok() {
        if *cancellation.borrow() {
            return;
        }
    }
}

/// Run a size-prefiltered, four-segment BLAKE3 check. Individual source errors
/// are reported and skipped; cancellation returns a partial report.
pub async fn run<F>(
    token: u64,
    inputs: Vec<DuplicateCheckItem>,
    mut emit: F,
) -> Result<DuplicateCheckReport>
where
    F: FnMut(DuplicateCheckEvent) + Send,
{
    let mut cancellation = start(token)?;
    let _guard = SessionGuard(token);
    let unsupported_count = inputs
        .iter()
        .filter(|item| {
            item.file_size > 0 && !matches!(item.source_type.as_str(), "local" | "smb" | "webdav")
        })
        .count();
    let mut failures = Vec::new();
    if unsupported_count > 0 {
        let failure = DuplicateCheckFailure {
            episode_id: 0,
            file_name: "Android 文件夹".to_string(),
            message: format!(
                "已跳过 {unsupported_count} 个 SAF 文件；当前 Rust 核心不能直接随机读取 content://"
            ),
        };
        emit(DuplicateCheckEvent::Warning(failure.clone()));
        failures.push(failure);
    }
    let candidates = prefilter_by_size(inputs)?;
    let total = candidates.len() as i64;
    let mut checked = 0i64;
    let mut fingerprints = BTreeMap::<(i64, String), Vec<DuplicateCheckItem>>::new();

    for item in candidates {
        if cancelled(&cancellation) {
            break;
        }
        emit(DuplicateCheckEvent::Progress {
            current: checked,
            total,
            message: item.file_name.clone(),
        });
        match fingerprint(&item, &mut cancellation).await {
            Ok(hash) => {
                fingerprints
                    .entry((item.file_size, hash))
                    .or_default()
                    .push(item);
            }
            Err(_) if cancelled(&cancellation) => break,
            Err(error) => {
                let failure = DuplicateCheckFailure {
                    episode_id: item.episode_id,
                    file_name: item.file_name,
                    message: format!("{error:#}"),
                };
                emit(DuplicateCheckEvent::Warning(failure.clone()));
                failures.push(failure);
            }
        }
        checked += 1;
    }

    let was_cancelled = cancelled(&cancellation);
    let mut groups = fingerprints
        .into_iter()
        .filter_map(|((file_size, sparse_hash), mut items)| {
            if items.len() < 2 {
                return None;
            }
            items.sort_by(|left, right| {
                left.anime_title
                    .cmp(&right.anime_title)
                    .then_with(|| left.episode_no.cmp(&right.episode_no))
                    .then_with(|| left.file_name.cmp(&right.file_name))
            });
            Some(DuplicateCandidateGroup {
                file_size,
                sparse_hash,
                items,
            })
        })
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| {
        right
            .file_size
            .cmp(&left.file_size)
            .then_with(|| left.sparse_hash.cmp(&right.sparse_hash))
    });
    for group in &groups {
        emit(DuplicateCheckEvent::Group(group.clone()));
    }
    emit(DuplicateCheckEvent::Done {
        checked,
        total,
        cancelled: was_cancelled,
    });
    Ok(DuplicateCheckReport {
        groups,
        failures,
        checked,
        total,
        cancelled: was_cancelled,
    })
}

fn prefilter_by_size(inputs: Vec<DuplicateCheckItem>) -> Result<Vec<DuplicateCheckItem>> {
    let mut seen = HashSet::new();
    let mut by_size = HashMap::<i64, Vec<DuplicateCheckItem>>::new();
    for input in inputs {
        if !seen.insert(input.episode_id) {
            anyhow::bail!("剧集 {} 重复出现在检查输入中", input.episode_id);
        }
        if input.file_size <= 0 || !matches!(input.source_type.as_str(), "local" | "smb" | "webdav")
        {
            continue;
        }
        by_size.entry(input.file_size).or_default().push(input);
    }
    let mut candidates = by_size
        .into_iter()
        .filter(|(_, items)| items.len() > 1)
        .flat_map(|(_, items)| items)
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        right
            .file_size
            .cmp(&left.file_size)
            .then_with(|| left.episode_id.cmp(&right.episode_id))
    });
    Ok(candidates)
}

async fn fingerprint(
    item: &DuplicateCheckItem,
    cancellation: &mut watch::Receiver<bool>,
) -> Result<String> {
    let expected_size = u64::try_from(item.file_size).context("文件大小无效")?;
    let ranges = sample_ranges(expected_size);
    let chunks = match item.source_type.as_str() {
        "local" => read_local_ranges(&item.file_path, expected_size, &ranges, cancellation).await?,
        "smb" => {
            validate_smb_uri_matches_active_credentials(&item.file_path)?;
            crate::smb::read_exact_ranges(&item.file_path, expected_size, &ranges, cancellation)
                .await?
        }
        "webdav" => {
            crate::webdav::read_exact_ranges(&item.file_path, expected_size, &ranges, cancellation)
                .await?
        }
        source => anyhow::bail!("暂不支持检查来源 {source}"),
    };
    Ok(hash_chunks(expected_size, &ranges, &chunks))
}

fn sample_ranges(size: u64) -> Vec<(u64, u64)> {
    if size == 0 {
        return Vec::new();
    }
    if size <= FULL_READ_LIMIT {
        return vec![(0, size)];
    }
    let span = size - BLOCK_SIZE;
    vec![
        (0, BLOCK_SIZE),
        (span / 3, BLOCK_SIZE),
        (span.saturating_mul(2) / 3, BLOCK_SIZE),
        (span, BLOCK_SIZE),
    ]
}

fn hash_chunks(size: u64, ranges: &[(u64, u64)], chunks: &[Vec<u8>]) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(HASH_DOMAIN);
    hasher.update(&size.to_le_bytes());
    hasher.update(&(ranges.len() as u64).to_le_bytes());
    for ((offset, length), chunk) in ranges.iter().zip(chunks) {
        hasher.update(&offset.to_le_bytes());
        hasher.update(&length.to_le_bytes());
        hasher.update(&(chunk.len() as u64).to_le_bytes());
        hasher.update(chunk);
    }
    hasher.finalize().to_hex().to_string()
}

async fn read_local_ranges(
    path: &str,
    expected_size: u64,
    ranges: &[(u64, u64)],
    cancellation: &mut watch::Receiver<bool>,
) -> Result<Vec<Vec<u8>>> {
    let mut file = tokio::select! {
        _ = wait_cancelled(cancellation) => anyhow::bail!("检查已取消"),
        result = tokio::fs::File::open(path) => result.with_context(|| format!("无法打开本地文件 {path}"))?,
    };
    let before = file.metadata().await.context("无法读取本地文件信息")?;
    if !before.is_file() || before.len() != expected_size {
        anyhow::bail!("本地文件大小已变化，请重新扫描");
    }
    let before_modified = before.modified().ok();
    let mut chunks = Vec::with_capacity(ranges.len());
    for &(offset, length) in ranges {
        if cancelled(cancellation) {
            anyhow::bail!("检查已取消");
        }
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        let mut bytes = vec![0u8; length as usize];
        tokio::select! {
            _ = wait_cancelled(cancellation) => anyhow::bail!("检查已取消"),
            result = file.read_exact(&mut bytes) => result.context("本地文件分块读取不完整")?,
        };
        chunks.push(bytes);
    }
    let after = file.metadata().await.context("无法重新读取本地文件信息")?;
    if after.len() != expected_size || modified_changed(before_modified, after.modified().ok()) {
        anyhow::bail!("本地文件在检查期间发生变化");
    }
    Ok(chunks)
}

fn modified_changed(before: Option<SystemTime>, after: Option<SystemTime>) -> bool {
    matches!((before, after), (Some(before), Some(after)) if before != after)
}

fn validate_smb_uri_matches_active_credentials(uri: &str) -> Result<()> {
    let credentials = crate::smb::creds().context("SMB 尚未配置")?;
    let remote = Url::parse(uri).context("SMB 文件地址无效")?;
    if remote.scheme() != "smb"
        || !remote.username().is_empty()
        || remote.password().is_some()
        || remote.query().is_some()
        || remote.fragment().is_some()
    {
        anyhow::bail!("SMB 文件地址格式无效");
    }
    let active =
        Url::parse(&format!("smb://{}/", credentials.addr)).context("当前 SMB 主机地址无效")?;
    let same_host = remote
        .host_str()
        .zip(active.host_str())
        .is_some_and(|(remote, active)| remote.eq_ignore_ascii_case(active));
    if !same_host || remote.port().unwrap_or(445) != active.port().unwrap_or(445) {
        anyhow::bail!("该 SMB 文件不属于当前连接的主机");
    }
    let share = remote
        .path_segments()
        .and_then(|mut segments| segments.next())
        .filter(|share| !share.is_empty())
        .context("SMB 文件地址缺少共享名")?;
    let share = percent_decode_str(share)
        .decode_utf8()
        .context("SMB 共享名不是有效 UTF-8")?;
    if share.as_ref() != credentials.share {
        anyhow::bail!("该 SMB 文件不属于当前连接的共享");
    }
    if remote
        .path_segments()
        .map(|segments| segments.count())
        .unwrap_or(0)
        < 2
    {
        anyhow::bail!("SMB 文件地址缺少文件路径");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    static SESSION_TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
    static SMB_TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

    fn input(id: i64, path: String, size: i64) -> DuplicateCheckItem {
        DuplicateCheckItem {
            episode_id: id,
            anime_id: 1,
            anime_title: "Test".to_string(),
            episode_no: Some(id),
            file_name: format!("Episode {id}.mkv"),
            file_path: path,
            source_type: "local".to_string(),
            file_size: size,
        }
    }

    fn temp_dir(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "kurako-duplicate-{label}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn sample_ranges_are_full_for_small_files_and_four_disjoint_blocks_for_video() {
        assert_eq!(sample_ranges(100), vec![(0, 100)]);
        let size = BLOCK_SIZE * 8;
        let ranges = sample_ranges(size);
        assert_eq!(ranges.len(), 4);
        assert_eq!(ranges[0], (0, BLOCK_SIZE));
        assert_eq!(ranges[3], (size - BLOCK_SIZE, BLOCK_SIZE));
        for pair in ranges.windows(2) {
            assert!(pair[0].0 + pair[0].1 <= pair[1].0);
        }
    }

    #[test]
    fn size_prefilter_skips_unique_unknown_and_saf_entries() {
        let mut saf = input(4, "content://video".into(), 5);
        saf.source_type = "saf".into();
        let candidates = prefilter_by_size(vec![
            input(1, "/one".into(), 10),
            input(2, "/two".into(), 10),
            input(3, "/unique".into(), 20),
            input(5, "/unknown".into(), 0),
            saf,
        ])
        .unwrap();
        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.episode_id)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
    }

    #[test]
    fn duplicate_episode_ids_are_rejected() {
        assert!(prefilter_by_size(vec![
            input(1, "/one".into(), 10),
            input(1, "/two".into(), 10),
        ])
        .is_err());
    }

    #[tokio::test]
    async fn local_checker_groups_matching_samples_and_skips_unique_sizes() {
        let _guard = SESSION_TEST_LOCK.lock().unwrap();
        *SESSION.lock().unwrap() = None;
        let dir = temp_dir("local-groups");
        let first = dir.join("first.mkv");
        let second = dir.join("second.mkv");
        let unique = dir.join("unique.mkv");
        let bytes = vec![7u8; (BLOCK_SIZE * 8) as usize];
        std::fs::write(&first, &bytes).unwrap();
        std::fs::write(&second, &bytes).unwrap();
        std::fs::write(&unique, b"unique-size").unwrap();
        let token = begin_session().unwrap();
        let report = run(
            token,
            vec![
                input(1, first.to_string_lossy().into_owned(), bytes.len() as i64),
                input(2, second.to_string_lossy().into_owned(), bytes.len() as i64),
                input(3, unique.to_string_lossy().into_owned(), 11),
            ],
            |_| {},
        )
        .await
        .unwrap();
        assert!(!report.cancelled);
        assert_eq!(report.total, 2);
        assert_eq!(report.checked, 2);
        assert_eq!(report.groups.len(), 1);
        assert_eq!(report.groups[0].items.len(), 2);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn saf_items_are_reported_as_skipped() {
        let _guard = SESSION_TEST_LOCK.lock().unwrap();
        *SESSION.lock().unwrap() = None;
        let mut saf = input(1, "content://video/1".into(), 100);
        saf.source_type = "saf".into();
        let token = begin_session().unwrap();
        let report = run(token, vec![saf], |_| {}).await.unwrap();
        assert_eq!(report.checked, 0);
        assert_eq!(report.failures.len(), 1);
        assert!(report.failures[0].message.contains("已跳过 1 个 SAF 文件"));
    }

    #[tokio::test]
    async fn sparse_checker_only_reports_sampling_evidence() {
        let dir = temp_dir("sparse-limit");
        let first = dir.join("first.mkv");
        let second = dir.join("second.mkv");
        let size = (BLOCK_SIZE * 8) as usize;
        let bytes = vec![3u8; size];
        let mut differs_outside_samples = bytes.clone();
        differs_outside_samples[(BLOCK_SIZE * 3 / 2) as usize] = 9;
        std::fs::write(&first, &bytes).unwrap();
        std::fs::write(&second, &differs_outside_samples).unwrap();
        let (_tx, mut cancellation) = watch::channel(false);
        let first_hash = fingerprint(
            &input(1, first.to_string_lossy().into_owned(), size as i64),
            &mut cancellation,
        )
        .await
        .unwrap();
        let second_hash = fingerprint(
            &input(2, second.to_string_lossy().into_owned(), size as i64),
            &mut cancellation,
        )
        .await
        .unwrap();
        assert_eq!(first_hash, second_hash);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn sampled_difference_changes_the_hash() {
        let dir = temp_dir("sampled-difference");
        let first = dir.join("first.mkv");
        let second = dir.join("second.mkv");
        let size = (BLOCK_SIZE * 8) as usize;
        let bytes = vec![3u8; size];
        let mut different = bytes.clone();
        different[0] = 9;
        std::fs::write(&first, &bytes).unwrap();
        std::fs::write(&second, &different).unwrap();
        let (_tx, mut cancellation) = watch::channel(false);
        let first_hash = fingerprint(
            &input(1, first.to_string_lossy().into_owned(), size as i64),
            &mut cancellation,
        )
        .await
        .unwrap();
        let second_hash = fingerprint(
            &input(2, second.to_string_lossy().into_owned(), size as i64),
            &mut cancellation,
        )
        .await
        .unwrap();
        assert_ne!(first_hash, second_hash);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn cancellation_is_scoped_to_the_matching_token() {
        let _guard = SESSION_TEST_LOCK.lock().unwrap();
        *SESSION.lock().unwrap() = None;
        let token = begin_session().unwrap();
        let mut receiver = start(token).unwrap();
        cancel(token + 1);
        assert!(!cancelled(&receiver));
        cancel(token);
        wait_cancelled(&mut receiver).await;
        assert!(cancelled(&receiver));
        finish(token);
        assert!(begin_session().is_ok());
        let next = SESSION.lock().unwrap().as_ref().unwrap().token;
        cancel(next);
    }

    #[test]
    fn smb_uri_must_match_active_host_port_and_share() {
        let _guard = SMB_TEST_LOCK.lock().unwrap();
        crate::smb::set_creds(Some(crate::smb::SmbCreds {
            addr: "nas.example.test:445".into(),
            share: "Anime Library".into(),
            user: "test".into(),
            password: "test".into(),
        }));
        assert!(validate_smb_uri_matches_active_credentials(
            "smb://nas.example.test/Anime%20Library/show/01.mkv"
        )
        .is_ok());
        assert!(validate_smb_uri_matches_active_credentials(
            "smb://other.example.test/Anime%20Library/show/01.mkv"
        )
        .is_err());
        assert!(validate_smb_uri_matches_active_credentials(
            "smb://nas.example.test/Other/show/01.mkv"
        )
        .is_err());
        crate::smb::set_creds(None);
    }

    #[test]
    fn hash_domain_includes_size_offsets_and_lengths() {
        let bytes = vec![vec![1, 2, 3]];
        assert_ne!(
            hash_chunks(3, &[(0, 3)], &bytes),
            hash_chunks(4, &[(0, 3)], &bytes)
        );
        assert_ne!(
            hash_chunks(3, &[(0, 3)], &bytes),
            hash_chunks(3, &[(1, 3)], &bytes)
        );
    }

    #[test]
    fn callbacks_can_be_collected_without_frb_models() {
        let events = Arc::new(Mutex::new(Vec::<DuplicateCheckEvent>::new()));
        let clone = events.clone();
        let callback = move |event| clone.lock().unwrap().push(event);
        callback(DuplicateCheckEvent::Done {
            checked: 0,
            total: 0,
            cancelled: false,
        });
        assert_eq!(events.lock().unwrap().len(), 1);
    }
}
