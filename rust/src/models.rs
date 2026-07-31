use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryFolder {
    pub id: i64,
    pub path: String,
    pub added_at: i64,
    /// Smaller values are scanned first and win exact filename conflicts.
    pub priority: i64,
    /// Unix seconds of the last scan, or None if never scanned. Used to skip
    /// unchanged folders during incremental scans.
    pub last_scanned: Option<i64>,
    /// Where this folder lives: "local" (POSIX path) or "saf" (Android tree URI).
    pub source_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Anime {
    pub id: i64,
    pub title_raw: String,
    pub bangumi_id: Option<i64>,
    pub name: Option<String>,
    pub name_cn: Option<String>,
    pub summary: Option<String>,
    pub cover_url: Option<String>,
    pub air_date: Option<String>,
    pub total_eps: Option<i64>,
    /// Bangumi community score (0-10).
    pub rating: Option<f64>,
    /// Number of votes behind `rating`.
    pub rating_total: Option<i64>,
    /// Site-wide rank ("Bangumi Ranked #N").
    pub rating_rank: Option<i64>,
    /// Vote histogram "n1,n2,...,n10" (score 1 → 10), for the rating chart.
    pub rating_counts: Option<String>,
    /// Broadcast weekday derived from air_date: 1=Mon .. 7=Sun.
    pub air_weekday: Option<i64>,
    /// Top Bangumi tags, comma-separated.
    pub tags: Option<String>,
    /// Top Bangumi tags with per-subject usage counts, serialized as JSON.
    pub tag_counts: Option<String>,
    /// An incremental scan inserted at least one new episode for this entry.
    pub has_new_files: bool,
    /// Bangumi collection type for the logged-in user:
    /// 0=none, 1=想看, 2=看过, 3=在看, 4=搁置, 5=抛弃.
    pub collection: i64,
    /// "high" | "low" | "none"
    pub match_confidence: String,
    pub corrected: bool,
    /// Distinct numbered episodes on disk (duplicate sources counted once).
    pub episode_count: i64,
    pub watched_count: i64,
    /// Unnumbered files: menus, NCOP/NCED, specials.
    pub special_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Episode {
    pub id: i64,
    pub anime_id: i64,
    pub file_path: String,
    pub file_name: String,
    pub episode_no: Option<i64>,
    pub title: Option<String>,
    pub resolution: Option<String>,
    pub release_group: Option<String>,
    pub watched: bool,
    pub last_position_ms: i64,
    pub duration_ms: i64,
    /// "local" = file_path is a POSIX path; "saf" = file_path is a content:// URI.
    pub source_type: String,
    /// Whether a completed download exists for this exact remote URI.
    pub is_downloaded: bool,
}

/// A video file discovered by a Dart-side enumerator (Android SAF), handed to
/// Rust for recognition/grouping. Mirrors `scan::ScannedFile` but frb-exported.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannedFile {
    /// content:// document URI (Android) — stored as the episode's file_path.
    pub uri: String,
    pub file_name: String,
    /// Source-reported byte size. Zero means unknown and cannot verify download
    /// recovery or suspected-duplicate comparisons.
    pub file_size: i64,
    /// Folder path from the library root ("" = root), "/"-separated.
    pub relative_parent: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanFileBatch {
    pub files: Vec<ScannedFile>,
    /// True when an incremental scan reused this folder's existing database
    /// rows instead of walking the unchanged local directory again.
    pub skipped_unchanged: bool,
}

/// A Bangumi search candidate, shown in the manual-correction dialog.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BangumiSubject {
    pub id: i64,
    pub name: String,
    pub name_cn: String,
    pub summary: String,
    pub cover_url: Option<String>,
    pub air_date: Option<String>,
    pub eps: Option<i64>,
    pub rating: Option<f64>,
    pub rating_total: Option<i64>,
    pub rating_rank: Option<i64>,
    /// Vote histogram "n1,n2,...,n10" (score 1 → 10).
    pub rating_counts: Option<String>,
    pub tags: Vec<String>,
    /// JSON array of `{name, count}` objects corresponding to `tags`.
    pub tag_counts: Option<String>,
}

/// A user-blocked item. `kind` is "anime" (matches anime.title_raw — whole
/// group skipped at scan time) or "file" (matches episodes.file_path).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlacklistEntry {
    pub id: i64,
    pub kind: String,
    pub value: String,
    pub created_at: i64,
}

/// An external subtitle file found next to a video. `uri` identifies the source
/// (a local absolute path or an `smb://` URI); it is prepared for mpv separately
/// so every platform receives normalized UTF-8 text.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleCandidate {
    pub file_name: String,
    pub uri: String,
}

/// A subtitle ready for libmpv. Text subtitles are normalized into a temporary
/// UTF-8 file; binary/local subtitles may reuse their source; SMB binary data
/// can still use the loopback proxy. Optional cleanup fields tell Dart what to
/// release only after mpv unloads the track.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreparedSubtitle {
    pub uri: String,
    pub temporary_path: Option<String>,
    pub proxy_url: Option<String>,
}

/// One file server announced by a bounded discovery protocol. Discovery never
/// authenticates or changes the active media session.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiscoveredServer {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub protocol: String,
    pub discovery_source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SmbShareInfo {
    pub name: String,
    pub comment: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SmbShareListResult {
    pub shares: Vec<SmbShareInfo>,
    /// Present only after authentication succeeded but automatic share
    /// enumeration was unavailable. The UI may then offer manual share entry.
    pub warning: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteDirectory {
    /// Share-relative path; empty means the share root.
    pub path: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteEntry {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    pub size: i64,
}

/// Progress event streamed back to Dart during an SMB download.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub bytes_done: i64,
    pub bytes_total: i64,
}

/// A completed remote-to-local download, tracked so playback can prefer the
/// local copy and the UI can manage (list/delete) downloads. `smb_uri` retains
/// its historical field name but may contain an SMB or WebDAV URI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadEntry {
    pub id: i64,
    pub smb_uri: String,
    pub local_path: String,
    pub bytes_total: i64,
    pub created_at: i64,
}

/// A download joined with its live library metadata or its retained match
/// snapshot when the library entry has since been removed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadDetail {
    pub id: i64,
    pub smb_uri: String,
    pub local_path: String,
    pub bytes_total: i64,
    pub created_at: i64,
    pub anime_id: Option<i64>,
    pub anime_title: Option<String>,
    pub cover_url: Option<String>,
    pub episode_no: Option<i64>,
    pub file_name: String,
}

/// One indexed video inspected by the explicit, report-only duplicate checker.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DuplicateCheckItem {
    pub episode_id: i64,
    pub anime_id: i64,
    pub anime_title: String,
    pub episode_no: Option<i64>,
    pub file_name: String,
    pub file_path: String,
    /// `local` | `smb` | `webdav`. Android SAF is reported as unsupported.
    pub source_type: String,
    pub file_size: i64,
}

/// Files whose size and four sparse content samples match. This is evidence of
/// a likely duplicate, not a complete-file equality guarantee.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DuplicateCandidateGroup {
    pub file_size: i64,
    pub sparse_hash: String,
    pub items: Vec<DuplicateCheckItem>,
}

/// Streamed state for the manually started duplicate checker.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuplicateCheckProgress {
    /// `progress` | `warning` | `group` | `done` | `cancelled`
    pub stage: String,
    pub current: i64,
    pub total: i64,
    pub message: String,
    pub group: Option<DuplicateCandidateGroup>,
}

/// Progress event streamed back to Dart during a scan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanProgress {
    /// "scanning" | "matching" | "warning" | "done"
    pub stage: String,
    pub current: i64,
    pub total: i64,
    pub message: String,
}
