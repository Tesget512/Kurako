use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryFolder {
    pub id: i64,
    pub path: String,
    pub added_at: i64,
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
}

/// A video file discovered by a Dart-side enumerator (Android SAF), handed to
/// Rust for recognition/grouping. Mirrors `scan::ScannedFile` but frb-exported.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScannedFile {
    /// content:// document URI (Android) — stored as the episode's file_path.
    pub uri: String,
    pub file_name: String,
    /// Folder path from the library root ("" = root), "/"-separated.
    pub relative_parent: String,
}

/// An SMB server found on the current private IPv4 network. Discovery only
/// proves that TCP/445 is reachable; authentication happens separately.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmbServer {
    pub host: String,
}

/// A disk share exposed by an authenticated SMB server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmbShare {
    pub name: String,
    pub comment: String,
}

/// A directory available below the currently authenticated SMB share.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmbDirectory {
    /// Share-relative path, with `/` separators. Empty means the share root.
    pub path: String,
    pub name: String,
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

/// An external subtitle file found next to a video. `uri` is what mpv should
/// load: a local absolute path (local sources) or a loopback proxy URL (SMB).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleCandidate {
    pub file_name: String,
    pub uri: String,
}

/// Progress event streamed back to Dart during an SMB download.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub bytes_done: i64,
    pub bytes_total: i64,
}

/// A completed SMB→local download, tracked so playback can prefer the local
/// copy and the UI can manage (list/delete) downloads.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadEntry {
    pub id: i64,
    pub smb_uri: String,
    pub local_path: String,
    pub bytes_total: i64,
    pub created_at: i64,
}

/// A download joined with its library episode/anime (LEFT JOIN — the episode
/// may have been removed from the library, in which case the anime fields are
/// None and only the raw file info remains).
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

/// Progress event streamed back to Dart during a scan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanProgress {
    /// "scanning" | "matching" | "done" | "error"
    pub stage: String,
    pub current: i64,
    pub total: i64,
    pub message: String,
}
