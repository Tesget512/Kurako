use crate::frb_generated::StreamSink;
use crate::models::{
    Anime, BangumiSubject, BlacklistEntry, DiscoveredServer, DownloadEntry, DownloadProgress,
    DuplicateCheckProgress, Episode, LibraryFolder, PreparedSubtitle, RemoteDirectory, RemoteEntry,
    ScanFileBatch, ScanProgress, SmbShareListResult, SubtitleCandidate,
};
use crate::{bangumi, db, recognize, scan, scan_control, sidecar, smb};
use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;

static RT: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        // 4 (was 2): the SMB loopback proxy holds a streaming task per open
        // connection; during rapid episode/anime switching an old stream stuck
        // on a slow NAS read plus the accept loop could exhaust 2 threads and
        // freeze further SMB calls (block_on). 4 gives headroom for switches.
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("tokio runtime")
});

static DOWNLOAD_DIRECTORY: Lazy<std::sync::Mutex<Option<String>>> =
    Lazy::new(|| std::sync::Mutex::new(None));

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn configured_download_directory() -> Option<String> {
    DOWNLOAD_DIRECTORY.lock().unwrap().clone()
}

fn download_match_is_valid(matched: &db::DownloadPathMatch) -> bool {
    std::fs::metadata(&matched.local_path)
        .map(|metadata| {
            metadata.is_file()
                && metadata.len() > 0
                && (matched.exact_uri || metadata.len() as i64 == matched.bytes_total)
        })
        .unwrap_or(false)
}

fn recover_download_records(download_dir: &str) -> Result<i64, String> {
    let mut recovered = db::rebase_download_paths(download_dir).map_err(|e| e.to_string())?;
    let entries = match std::fs::read_dir(download_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(recovered),
        Err(error) => return Err(error.to_string()),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !path.is_file() || !smb::is_video(file_name) {
            continue;
        }
        let local_path = path.to_string_lossy().to_string();
        let bytes_total = entry
            .metadata()
            .map(|metadata| metadata.len() as i64)
            .unwrap_or(0);
        if bytes_total <= 0 {
            continue;
        }
        if db::recover_download_file(&local_path, file_name, bytes_total, now_secs())
            .map_err(|e| e.to_string())?
        {
            recovered += 1;
        }
    }
    Ok(recovered)
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Open (and create if needed) the SQLite database at the given path.
pub fn init_db(db_path: String) -> Result<(), String> {
    sidecar::set_data_dir_from_db(&db_path);
    db::init(&db_path).map_err(|e| e.to_string())
}

/// Register the effective local download directory and recover video files
/// which survived while their SQLite download records did not.
pub fn set_download_directory(download_dir: String) -> Result<i64, String> {
    let normalized = download_dir.trim().to_string();
    *DOWNLOAD_DIRECTORY.lock().unwrap() = if normalized.is_empty() {
        None
    } else {
        Some(normalized.clone())
    };
    if normalized.is_empty() {
        Ok(0)
    } else {
        recover_download_records(&normalized)
    }
}

/// Configure the optional Bangumi personal access token.
pub fn set_bangumi_token(token: Option<String>) {
    bangumi::set_token(token);
}

/// Route Bangumi API calls through the mainland-reachable mirror
/// (bgmapi.anibt.net, Soyorin's bangumi-proxy instance) instead of api.bgm.tv.
/// OAuth always stays on the official domain.
pub fn set_bangumi_mirror(enabled: bool) {
    bangumi::set_mirror(enabled);
}

// ---- Bangumi OAuth 2.0 ----

/// Result of an OAuth token exchange/refresh, surfaced to Dart for persistence.
pub struct OAuthResult {
    pub access_token: String,
    pub refresh_token: String,
    /// Absolute Unix expiry time (seconds), computed from expires_in.
    pub expires_at: i64,
    pub user_id: i64,
}

impl From<bangumi::OAuthToken> for OAuthResult {
    fn from(t: bangumi::OAuthToken) -> Self {
        OAuthResult {
            access_token: t.access_token,
            refresh_token: t.refresh_token,
            expires_at: now_secs() + t.expires_in.max(0),
            user_id: t.user_id,
        }
    }
}

/// Build the browser authorization URL for the login flow. Uses the app's
/// baked-in client id and registered callback.
pub fn oauth_authorize_url() -> String {
    bangumi::authorize_url(bangumi::OAUTH_CLIENT_ID, bangumi::OAUTH_REDIRECT_URI)
}

/// The registered OAuth callback URL (for the Dart loopback server to bind).
pub fn oauth_redirect_uri() -> String {
    bangumi::OAUTH_REDIRECT_URI.to_string()
}

/// Exchange an authorization code (from the callback) for tokens.
pub fn oauth_exchange_code(code: String) -> Result<OAuthResult, String> {
    RT.block_on(async {
        bangumi::exchange_code(
            bangumi::OAUTH_CLIENT_ID,
            bangumi::OAUTH_CLIENT_SECRET,
            &code,
            bangumi::OAUTH_REDIRECT_URI,
        )
        .await
    })
    .map(Into::into)
    .map_err(|e| e.to_string())
}

/// Refresh an access token using a stored refresh token.
pub fn oauth_refresh(refresh_token: String) -> Result<OAuthResult, String> {
    RT.block_on(async {
        bangumi::refresh_token(
            bangumi::OAUTH_CLIENT_ID,
            bangumi::OAUTH_CLIENT_SECRET,
            &refresh_token,
            bangumi::OAUTH_REDIRECT_URI,
        )
        .await
    })
    .map(Into::into)
    .map_err(|e| e.to_string())
}

/// The detected system HTTP proxy (e.g. "http://127.0.0.1:7890"), or None.
/// The Flutter side uses this to route cover-image requests through the same
/// proxy the Rust HTTP client uses.
pub fn system_proxy() -> Option<String> {
    bangumi::detect_system_proxy()
}

// ---- Library folders ----

pub fn add_library_folder(path: String, source_type: String) -> Result<LibraryFolder, String> {
    let id = db::add_folder(&path, now_secs(), &source_type).map_err(|e| e.to_string())?;
    db::list_folders()
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|folder| folder.id == id)
        .ok_or_else(|| "新增文件夹后无法读取记录".to_string())
}

pub fn remove_library_folder(id: i64) -> Result<(), String> {
    let Some(folder) = db::list_folders()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|folder| folder.id == id)
    else {
        return Ok(());
    };
    let prefixes = prune_prefixes_for(folder.id, &folder.source_type);
    db::remove_folder(id, &folder.source_type, &prefixes).map_err(|error| error.to_string())
}

pub fn list_library_folders() -> Result<Vec<LibraryFolder>, String> {
    db::list_folders().map_err(|e| e.to_string())
}

pub fn reorder_library_folders(ids: Vec<i64>) -> Result<(), String> {
    db::reorder_folders(&ids).map_err(|e| e.to_string())
}

// ---- Library reads ----

pub fn list_anime() -> Result<Vec<Anime>, String> {
    db::list_anime().map_err(|e| e.to_string())
}

pub fn get_anime(id: i64) -> Result<Option<Anime>, String> {
    db::get_anime(id).map_err(|e| e.to_string())
}

pub fn list_episodes(anime_id: i64) -> Result<Vec<Episode>, String> {
    db::list_episodes(anime_id).map_err(|e| e.to_string())
}

// ---- Explicit suspected-duplicate check (never part of scanning) ----

pub fn duplicate_check_begin() -> Result<i64, String> {
    let token = crate::duplicate_check::begin().map_err(|error| error.to_string())?;
    i64::try_from(token).map_err(|_| "疑似重复检查会话编号溢出".to_string())
}

pub fn duplicate_check_run(
    sink: StreamSink<DuplicateCheckProgress>,
    token: i64,
) -> Result<(), String> {
    let token = u64::try_from(token).map_err(|_| "疑似重复检查会话无效".to_string())?;
    let items = match db::duplicate_check_items() {
        Ok(items) => items,
        Err(error) => {
            crate::duplicate_check::cancel(token);
            return Err(error.to_string());
        }
    };
    RT.block_on(async {
        crate::duplicate_check::run(token, items, |event| {
            use crate::duplicate_check::DuplicateCheckEvent;
            let progress = match event {
                DuplicateCheckEvent::Progress {
                    current,
                    total,
                    message,
                } => DuplicateCheckProgress {
                    stage: "progress".to_string(),
                    current,
                    total,
                    message,
                    group: None,
                },
                DuplicateCheckEvent::Warning(warning) => DuplicateCheckProgress {
                    stage: "warning".to_string(),
                    current: 0,
                    total: 0,
                    message: format!("{}：{}", warning.file_name, warning.message),
                    group: None,
                },
                DuplicateCheckEvent::Group(group) => DuplicateCheckProgress {
                    stage: "group".to_string(),
                    current: 0,
                    total: 0,
                    message: String::new(),
                    group: Some(group),
                },
                DuplicateCheckEvent::Done {
                    checked,
                    total,
                    cancelled,
                } => DuplicateCheckProgress {
                    stage: if cancelled { "cancelled" } else { "done" }.to_string(),
                    current: checked,
                    total,
                    message: String::new(),
                    group: None,
                },
            };
            let _ = sink.add(progress);
        })
        .await
    })
    .map(|_| ())
    .map_err(|error| error.to_string())
}

pub fn duplicate_check_cancel(token: i64) {
    if let Ok(token) = u64::try_from(token) {
        crate::duplicate_check::cancel(token);
    }
}

// ---- Playback progress ----

pub fn update_progress(episode_id: i64, position_ms: i64, duration_ms: i64) -> Result<(), String> {
    db::update_progress(episode_id, position_ms, duration_ms).map_err(|e| e.to_string())
}

pub fn set_watched(episode_id: i64, watched: bool) -> Result<(), String> {
    db::set_watched(episode_id, watched).map_err(|e| e.to_string())
}

// ---- Scan + auto-match (streams progress back to Dart) ----

pub fn scan_session_begin(incremental: bool) -> Result<(), String> {
    scan_control::begin(incremental)
        .then_some(())
        .ok_or_else(|| "已有扫描任务正在运行".to_string())
}

pub fn scan_session_cancel() {
    scan_control::cancel();
}

pub fn scan_session_is_cancelled() -> bool {
    scan_control::is_cancelled()
}

pub fn scan_session_close() {
    scan_control::finish();
}

pub fn enumerate_local_folder(folder_id: i64, incremental: bool) -> Result<ScanFileBatch, String> {
    if !scan_control::is_active() {
        return Err("扫描会话尚未开始".to_string());
    }
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }
    let folder = db::list_folders()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|folder| folder.id == folder_id && folder.source_type == "local")
        .ok_or_else(|| "本地番剧文件夹不存在".to_string())?;
    let prefix = vec![folder.path.clone()];
    let mtime = scan::folder_max_mtime(&folder.path);
    if incremental && mtime > 0 && folder.last_scanned.is_some_and(|last| mtime <= last) {
        reconcile_existing_folder(folder.id, "local", &prefix)?;
        return Ok(ScanFileBatch {
            files: Vec::new(),
            skipped_unchanged: true,
        });
    }
    let files = scan::enumerate_library(&folder.path)
        .into_iter()
        .map(|file| crate::models::ScannedFile {
            uri: file.uri,
            file_name: file.file_name,
            file_size: file.file_size,
            relative_parent: file.relative_parent,
        })
        .collect();
    Ok(ScanFileBatch {
        files,
        skipped_unchanged: false,
    })
}

/// Scan all library folders, group files into anime, then auto-match each new
/// anime against Bangumi. Emits ScanProgress events throughout.
///
/// When `incremental` is true, folders whose newest file/dir mtime is older than
/// their last recorded scan time are skipped entirely — dramatically faster on
/// large libraries where only a few folders changed.
pub fn scan_and_match(sink: StreamSink<ScanProgress>, incremental: bool) -> Result<(), String> {
    scan_session_begin(incremental)?;
    let result = (|| {
        for folder in db::list_folders().map_err(|error| error.to_string())? {
            if folder.source_type != "local" {
                continue;
            }
            let batch = enumerate_local_folder(folder.id, incremental)?;
            if batch.skipped_unchanged {
                continue;
            }
            process_scanned_folder(&sink, folder.id, batch.files, folder.source_type)?;
        }
        finish_scan_session(&sink)
    })();
    scan_session_close();
    result
}

/// Scan a folder whose files were enumerated on the Dart side (Android SAF) or
/// by the Rust SMB client. `files` carries locator URIs + relative folder paths;
/// Rust does only the recognition/grouping/matching. `source_type` is stored on
/// each episode so playback knows how to resolve the URI ("saf" | "smb").
pub fn scan_files_and_match(
    sink: StreamSink<ScanProgress>,
    folder_id: i64,
    files: Vec<crate::models::ScannedFile>,
    source_type: String,
) -> Result<(), String> {
    process_scanned_folder(&sink, folder_id, files, source_type)
}

fn process_scanned_folder(
    sink: &StreamSink<ScanProgress>,
    folder_id: i64,
    files: Vec<crate::models::ScannedFile>,
    source_type: String,
) -> Result<(), String> {
    if !scan_control::is_active() {
        return Err("扫描会话尚未开始".to_string());
    }
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }
    let had_scan_baseline = db::list_folders()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|folder| folder.id == folder_id)
        .is_some_and(|folder| folder.last_scanned.is_some());
    let mark_new_files = scan_control::is_incremental() && had_scan_baseline;
    let (files, skipped_duplicates) = scan_control::claim_files(files);
    if skipped_duplicates > 0 {
        let _ = sink.add(ScanProgress {
            stage: "scanning".to_string(),
            current: 0,
            total: 0,
            message: format!("按文件夹优先级跳过 {skipped_duplicates} 个同名文件"),
        });
    }
    let scanned: Vec<scan::ScannedFile> = files
        .iter()
        .map(|f| scan::ScannedFile {
            uri: f.uri.clone(),
            file_name: f.file_name.clone(),
            file_size: f.file_size,
            relative_parent: f.relative_parent.clone(),
        })
        .collect();
    let groups = scan::group_files(scanned);
    // Scope deletion-pruning to this folder's locator prefix so files removed
    // from the SMB share / SAF tree are dropped from the library too.
    let prefixes = prune_prefixes_for(folder_id, &source_type);
    process_groups(
        groups,
        folder_id,
        &source_type,
        prefixes,
        mark_new_files,
        sink,
    )?;
    db::set_folder_scanned(folder_id, now_secs()).map_err(|error| error.to_string())
}

pub fn finish_scan_and_match(sink: StreamSink<ScanProgress>) -> Result<(), String> {
    if !scan_control::is_active() {
        return Err("扫描会话尚未开始".to_string());
    }
    finish_scan_session(&sink)
}

pub fn claim_existing_folder_files(folder_id: i64) -> Result<i64, String> {
    let folder = db::list_folders()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|folder| folder.id == folder_id)
        .ok_or_else(|| "番剧文件夹不存在".to_string())?;
    let prefixes = prune_prefixes_for(folder.id, &folder.source_type);
    reconcile_existing_folder(folder.id, &folder.source_type, &prefixes)
}

fn reconcile_existing_folder(
    folder_id: i64,
    source_type: &str,
    prefixes: &[String],
) -> Result<i64, String> {
    let entries = db::adopt_episode_entries_for_folder(folder_id, source_type, prefixes)
        .map_err(|error| error.to_string())?;
    let conflicts = scan_control::claim_existing_entries(&entries);
    let removed = db::delete_episode_paths(&conflicts).map_err(|error| error.to_string())?;
    if removed > 0 {
        let _ = db::delete_empty_anime();
    }
    Ok(removed as i64)
}

/// The locator-URI prefix(es) covering one enumerated folder, used to scope
/// deletion-pruning. SAF tree URIs are already a clean prefix of their child
/// document URIs; SMB paths are normalized through the cached creds so they
/// match the `addr:port` form stored on episodes.
fn prune_prefixes_for(folder_id: i64, source_type: &str) -> Vec<String> {
    let folders = match db::list_folders() {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let Some(folder) = folders.into_iter().find(|f| f.id == folder_id) else {
        return Vec::new();
    };
    match source_type {
        "smb" => {
            // folder.path is smb://host/share/subdir (host as entered); rebuild
            // it from creds so it matches episode URIs (smb://addr:port/share/…).
            let subdir = smb_subdir_of(&folder.path);
            smb::uri_prefix(&subdir).into_iter().collect()
        }
        "webdav" => vec![format!("{}/", folder.path.trim_end_matches('/'))],
        // saf (and any other prefix-clean source): the folder path is already a
        // prefix of every file discovered under it.
        _ => vec![folder.path],
    }
}

/// Extract the share-relative sub-path from an `smb://host/share/sub/dir` URI.
fn smb_subdir_of(path: &str) -> String {
    let rest = path.strip_prefix("smb://").unwrap_or(path);
    let mut it = rest.splitn(3, '/');
    let _host = it.next();
    let _share = it.next();
    it.next().unwrap_or("").trim_matches('/').to_string()
}

// ---- SMB network share ----

/// Test-connect an SMB share and cache the credentials. Returns Err with a
/// human-readable message on failure so the UI can show it.
pub fn smb_connect(
    host: String,
    share: String,
    user: String,
    password: String,
) -> Result<(), String> {
    RT.block_on(async { smb::connect(&host, &share, &user, &password).await })
        .map_err(|e| e.to_string())
}

/// Discover Windows/NAS file servers through Bonjour's companion discovery
/// layer, WS-Discovery, and a bounded local TCP/445 fallback. This never
/// authenticates or alters the active SMB session.
pub fn discover_windows_file_servers() -> Vec<DiscoveredServer> {
    RT.block_on(crate::discovery::discover_windows_file_servers())
}

pub fn smb_list_shares(
    host: String,
    user: String,
    password: String,
) -> Result<SmbShareListResult, String> {
    RT.block_on(async { smb::list_shares(&host, &user, &password).await })
        .map_err(|error| error.to_string())
}

pub fn smb_setup_begin(
    host: String,
    share: String,
    user: String,
    password: String,
) -> Result<String, String> {
    RT.block_on(async { smb::setup_begin(&host, &share, &user, &password).await })
        .map_err(|error| error.to_string())
}

pub fn smb_setup_list_directories(
    token: String,
    subdir: String,
) -> Result<Vec<RemoteDirectory>, String> {
    RT.block_on(async { smb::setup_list_directories(&token, &subdir).await })
        .map_err(|error| error.to_string())
}

pub fn smb_setup_cancel(token: String) {
    smb::setup_cancel(&token);
}

pub fn smb_setup_commit(token: String) -> Result<(), String> {
    smb::setup_commit(&token).map_err(|error| error.to_string())
}

/// Restore cached SMB credentials on startup (from Dart's persisted settings)
/// without a network round-trip. Connection is opened lazily per operation.
pub fn smb_set_credentials(host: String, share: String, user: String, password: String) {
    if host.trim().is_empty() || share.trim_matches('/').is_empty() {
        smb::set_creds(None);
        return;
    }
    smb::set_creds(Some(smb::SmbCreds {
        addr: if host.contains(':') {
            host
        } else {
            format!("{host}:445")
        },
        share: share.trim_matches('/').to_string(),
        user,
        password,
    }));
}

/// Recursively enumerate video files under an SMB folder's sub-path.
pub fn smb_enumerate(subdir: String) -> Result<Vec<crate::models::ScannedFile>, String> {
    RT.block_on(async { smb::enumerate(&subdir).await })
        .map_err(|e| e.to_string())
}

/// Register an SMB file for playback and return a local HTTP URL libmpv can
/// play (the loopback proxy streams it, honouring Range/seek).
pub fn smb_playable_url(smb_uri: String) -> Result<String, String> {
    RT.block_on(async { smb::register_playable(&smb_uri).await })
        .map_err(|e| e.to_string())
}

/// Release a playback URL when done (frees the proxy token).
pub fn smb_release(url: String) {
    smb::unregister_playable(&url);
}

/// External subtitle files next to an SMB video (same dir + same stem prefix),
/// each pre-registered on the loopback proxy so mpv can load it.
pub fn smb_list_subtitles(smb_uri: String) -> Result<Vec<SubtitleCandidate>, String> {
    RT.block_on(async { smb::list_subtitles(&smb_uri).await })
        .map_err(|e| e.to_string())
}

/// Filter locally enumerated subtitle filenames through the same recognizer
/// used by SMB streaming, download, and downloaded-sidecar cleanup.
pub fn matching_subtitle_file_names(
    video_name: String,
    subtitle_names: Vec<String>,
) -> Vec<String> {
    subtitle_names
        .into_iter()
        .filter(|name| recognize::subtitle_matches_video(&video_name, name))
        .collect()
}

/// Normalize a local or SMB text subtitle into one strict UTF-8 cache file.
/// Binary `.sub` files retain their existing local/proxy behavior.
pub fn prepare_subtitle(
    source_uri: String,
    file_name: String,
    cache_dir: String,
) -> Result<PreparedSubtitle, String> {
    RT.block_on(async { crate::subtitle::prepare(&source_uri, &file_name, &cache_dir).await })
        .map_err(|error| error.to_string())
}

/// Release any loopback URL returned by a network subtitle backend. Calling
/// both registries is harmless and keeps Dart independent from proxy ports.
pub fn release_network_url(url: String) {
    smb::unregister_playable(&url);
    crate::webdav::unregister_playable(&url);
}

/// Cumulative bytes streamed by the SMB proxy. Dart polls this once a second
/// and shows the delta as transfer speed in the playback-info panel.
pub fn smb_proxy_stats() -> u64 {
    smb::proxy_bytes_served()
}

/// Cumulative bytes streamed by the WebDAV loopback playback proxy. Downloads
/// use a separate transfer path and are not included.
pub fn webdav_proxy_stats() -> u64 {
    crate::webdav::proxy_bytes_served()
}

// ---- SMB downloads ----

/// Download an SMB file to `dest_dir`, streaming progress. On success the
/// download is recorded so playback prefers the local copy from then on.
pub fn smb_download(
    sink: StreamSink<DownloadProgress>,
    smb_uri: String,
    dest_dir: String,
) -> Result<String, String> {
    *DOWNLOAD_DIRECTORY.lock().unwrap() = Some(dest_dir.clone());
    smb::reset_download_cancellation(&smb_uri);
    let existing = RT
        .block_on(async { smb::matching_existing_download(&smb_uri, &dest_dir).await })
        .ok()
        .flatten();
    if smb::download_was_cancelled(&smb_uri) {
        return Err("下载已取消".to_string());
    }
    let local = if let Some((path, size)) = existing {
        let _ = sink.add(DownloadProgress {
            bytes_done: size as i64,
            bytes_total: size as i64,
        });
        path
    } else {
        RT.block_on(async {
            smb::download(&smb_uri, &dest_dir, |done, total| {
                let _ = sink.add(DownloadProgress {
                    bytes_done: done as i64,
                    bytes_total: total as i64,
                });
            })
            .await
        })
        .map_err(|e| e.to_string())?
    };
    let subtitle_result = RT.block_on(async { smb::download_subtitles(&smb_uri, &dest_dir).await });
    if smb::download_was_cancelled(&smb_uri) {
        smb::remove_downloaded_subtitles(&local);
        let _ = std::fs::remove_file(&local);
        return Err("下载已取消".to_string());
    }
    if let Err(error) = subtitle_result {
        eprintln!("KURAKO could not download sidecar subtitles: {error:#}");
    }
    let size = std::fs::metadata(&local)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    db::add_download(&smb_uri, &local, size, now_secs()).map_err(|e| e.to_string())?;
    Ok(local)
}

/// Cancel one in-flight download by its SMB URI (checked between transfer chunks;
/// other concurrent downloads are unaffected).
pub fn smb_cancel_download(smb_uri: String) {
    smb::cancel_download(&smb_uri);
}

// ---- WebDAV network source ----

pub fn webdav_set_credentials(
    base_url: String,
    user: String,
    password: String,
    auth_mode: String,
    allow_insecure_tls: bool,
) -> Result<(), String> {
    if base_url.trim().is_empty() {
        return crate::webdav::set_creds(None).map_err(|error| error.to_string());
    }
    crate::webdav::set_creds(Some(crate::webdav::WebDavCreds {
        base_url,
        user,
        password,
        auth_mode,
        allow_insecure_tls,
    }))
    .map_err(|error| error.to_string())
}

pub fn webdav_test_connection() -> Result<Vec<RemoteEntry>, String> {
    RT.block_on(crate::webdav::test_connection())
        .map_err(|error| error.to_string())
}

pub fn webdav_setup_begin(
    base_url: String,
    user: String,
    password: String,
    auth_mode: String,
    allow_insecure_tls: bool,
) -> Result<String, String> {
    RT.block_on(crate::webdav::setup_begin(
        &base_url,
        &user,
        &password,
        &auth_mode,
        allow_insecure_tls,
    ))
    .map_err(|error| error.to_string())
}

pub fn webdav_setup_list_entries(
    token: String,
    subdir: String,
) -> Result<Vec<RemoteEntry>, String> {
    RT.block_on(crate::webdav::setup_list_entries(&token, &subdir))
        .map_err(|error| error.to_string())
}

pub fn webdav_setup_cancel(token: String) {
    crate::webdav::setup_cancel(&token);
}

pub fn webdav_setup_commit(token: String) -> Result<(), String> {
    crate::webdav::setup_commit(&token).map_err(|error| error.to_string())
}

pub fn webdav_list_entries(subdir: String) -> Result<Vec<RemoteEntry>, String> {
    RT.block_on(crate::webdav::list_entries(&subdir))
        .map_err(|error| error.to_string())
}

pub fn webdav_enumerate(source_uri: String) -> Result<Vec<crate::models::ScannedFile>, String> {
    RT.block_on(crate::webdav::enumerate_source(&source_uri))
        .map_err(|error| error.to_string())
}

pub fn webdav_uri_for_relative(subdir: String) -> Result<String, String> {
    crate::webdav::uri_for_relative(&subdir).map_err(|error| error.to_string())
}

pub fn webdav_playable_url(remote_uri: String) -> Result<String, String> {
    RT.block_on(crate::webdav::register_playable(&remote_uri))
        .map_err(|error| error.to_string())
}

pub fn webdav_release(url: String) {
    crate::webdav::unregister_playable(&url);
}

pub fn webdav_list_subtitles(remote_uri: String) -> Result<Vec<SubtitleCandidate>, String> {
    RT.block_on(crate::webdav::list_subtitles(&remote_uri))
        .map_err(|error| error.to_string())
}

pub fn webdav_download(
    sink: StreamSink<DownloadProgress>,
    remote_uri: String,
    dest_dir: String,
) -> Result<String, String> {
    *DOWNLOAD_DIRECTORY.lock().unwrap() = Some(dest_dir.clone());
    crate::webdav::reset_download_cancellation(&remote_uri);
    let existing = RT
        .block_on(crate::webdav::matching_existing_download(
            &remote_uri,
            &dest_dir,
        ))
        .ok()
        .flatten();
    let reused_existing = existing.is_some();
    if crate::webdav::download_was_cancelled(&remote_uri) {
        return Err("下载已取消".to_string());
    }
    let local = if let Some((path, size)) = existing {
        let _ = sink.add(DownloadProgress {
            bytes_done: size as i64,
            bytes_total: size as i64,
        });
        path
    } else {
        RT.block_on(crate::webdav::download(
            &remote_uri,
            &dest_dir,
            |done, total| {
                let _ = sink.add(DownloadProgress {
                    bytes_done: done as i64,
                    bytes_total: total as i64,
                });
            },
        ))
        .map_err(|error| error.to_string())?
    };
    let subtitles = RT.block_on(crate::webdav::download_subtitles(&remote_uri, &dest_dir));
    if crate::webdav::download_was_cancelled(&remote_uri) {
        if !reused_existing {
            smb::remove_downloaded_subtitles(&local);
            let _ = std::fs::remove_file(&local);
        }
        return Err("下载已取消".to_string());
    }
    if let Err(error) = subtitles {
        eprintln!("KURAKO could not download WebDAV sidecar subtitles: {error:#}");
    }
    let size = std::fs::metadata(&local)
        .map(|metadata| metadata.len() as i64)
        .unwrap_or(0);
    db::add_download(&remote_uri, &local, size, now_secs()).map_err(|error| error.to_string())?;
    Ok(local)
}

pub fn webdav_cancel_download(remote_uri: String) {
    crate::webdav::cancel_download(&remote_uri);
}

pub fn list_downloads() -> Result<Vec<DownloadEntry>, String> {
    db::list_downloads().map_err(|e| e.to_string())
}

/// Downloads joined with episode/anime info for the management page.
pub fn list_downloads_detailed() -> Result<Vec<crate::models::DownloadDetail>, String> {
    db::list_downloads_detailed().map_err(|e| e.to_string())
}

/// Delete a download: removes the record and the local file.
pub fn remove_download(id: i64) -> Result<(), String> {
    let path = db::remove_download(id).map_err(|e| e.to_string())?;
    if let Some(p) = path {
        smb::remove_downloaded_subtitles(&p);
        let _ = std::fs::remove_file(p);
    }
    Ok(())
}

/// The verified local copy for an exact URI or a strictly matched SMB/WebDAV
/// counterpart. Exact records retain their stale path long enough for Apple
/// app-container rebasing; cross-source records also verify the local byte size.
pub fn downloaded_local_path(smb_uri: String) -> Result<Option<String>, String> {
    let matched = db::download_local_match(&smb_uri).map_err(|e| e.to_string())?;
    match matched {
        Some(matched) if download_match_is_valid(&matched) => Ok(Some(matched.local_path)),
        Some(_) => {
            // App-container UUIDs are not stable. Rebase the authoritative
            // download row before treating its old absolute path as missing.
            if let Some(download_dir) = configured_download_directory() {
                db::rebase_download_paths(&download_dir).map_err(|e| e.to_string())?;
                if let Some(rebased) =
                    db::download_local_match(&smb_uri).map_err(|e| e.to_string())?
                {
                    if download_match_is_valid(&rebased) {
                        return Ok(Some(rebased.local_path));
                    }
                }
            }
            // Keep the URI and match snapshot. Only an explicit user delete may
            // remove a download row whose file cannot be verified.
            Ok(None)
        }
        None => recover_exact_download(&smb_uri),
    }
}

fn recover_exact_download(smb_uri: &str) -> Result<Option<String>, String> {
    let Some(download_dir) = configured_download_directory() else {
        return Ok(None);
    };
    let expected = if smb_uri.starts_with("smb://") {
        smb::expected_download_path(smb_uri, &download_dir)
    } else if smb_uri.starts_with("http://") || smb_uri.starts_with("https://") {
        crate::webdav::expected_download_path(smb_uri, &download_dir)
    } else {
        None
    };
    let Some(path) = expected else {
        return Ok(None);
    };
    let metadata = match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() && metadata.len() > 0 => metadata,
        _ => return Ok(None),
    };
    let belongs_to_library = if smb_uri.starts_with("smb://") {
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            return Ok(None);
        };
        db::unique_smb_episode_uri(file_name, metadata.len() as i64)
            .map_err(|error| error.to_string())?
            .as_deref()
            == Some(smb_uri)
    } else {
        // WebDAV download names include a parent-path hash prefix, so the
        // local leaf is intentionally different from the remote filename.
        // Validate the exact URI and its size captured during the latest scan.
        db::episode_uri_matches_size("webdav", smb_uri, metadata.len() as i64)
            .map_err(|error| error.to_string())?
    };
    if !belongs_to_library {
        return Ok(None);
    }
    let local_path = path.to_string_lossy().to_string();
    db::add_download(smb_uri, &local_path, metadata.len() as i64, now_secs())
        .map_err(|e| e.to_string())?;
    Ok(Some(local_path))
}

// ---- Snapshot sync (multi-device) ----
// Removed: SMB snapshots proved impractical (a snapshot from one device
// references that device's SMB path, and a restoring device that isn't
// connected to that same share can't play the entries).

/// Persist one successfully enumerated folder. Matching is deliberately
/// deferred until every source has passed through the shared filename-priority
/// filter, so lower-priority copies never trigger Bangumi requests.
fn process_groups(
    groups: Vec<scan::AnimeGroup>,
    folder_id: i64,
    source_type: &str,
    prune_prefixes: Vec<String>,
    mark_new_files: bool,
    sink: &StreamSink<ScanProgress>,
) -> Result<(), String> {
    let emit = |stage: &str, current: i64, total: i64, message: &str| {
        let _ = sink.add(ScanProgress {
            stage: stage.to_string(),
            current,
            total,
            message: message.to_string(),
        });
    };

    // Drop blacklisted items before touching the DB: whole groups blocked by
    // title, individual files blocked by path. Blocked entries thus never
    // reappear on rescan.
    let blocked_titles = db::blacklist_values("anime").map_err(|e| e.to_string())?;
    let blocked_files = db::blacklist_values("file").map_err(|e| e.to_string())?;
    let groups: Vec<scan::AnimeGroup> = groups
        .into_iter()
        .filter(|g| !blocked_titles.contains(&g.title))
        .map(|mut g| {
            g.files.retain(|f| !blocked_files.contains(&f.path));
            g
        })
        .filter(|g| !g.files.is_empty())
        .collect();

    let total = groups.len() as i64;
    for (i, g) in groups.iter().enumerate() {
        if scan_control::is_cancelled() {
            return Err("扫描已取消".to_string());
        }
        let anime_id = db::upsert_anime(&g.group_key, &g.title).map_err(|e| e.to_string())?;
        let mut inserted_episode = false;
        for ff in &g.files {
            if scan_control::is_cancelled() {
                return Err("扫描已取消".to_string());
            }
            inserted_episode |= db::upsert_episode(
                anime_id,
                folder_id,
                &ff.path,
                &ff.file_name,
                ff.file_size,
                ff.parsed.episode_no,
                ff.parsed.resolution.as_deref(),
                ff.parsed.release_group.as_deref(),
                source_type,
            )
            .map_err(|e| e.to_string())?;
        }
        if mark_new_files && inserted_episode {
            db::mark_anime_has_new_files(anime_id).map_err(|e| e.to_string())?;
        }
        emit("scanning", i as i64 + 1, total, &g.title);
    }

    // 1b. Prune episodes that disappeared from the scanned scope: anything of
    // this source under a walked prefix that we DIDN'T just find is gone from
    // disk/share, so delete it (and any anime left with no episodes). Runs after
    // the upserts so the kept set reflects everything currently present.
    if !prune_prefixes.is_empty() {
        let kept: std::collections::HashSet<String> = groups
            .iter()
            .flat_map(|g| g.files.iter().map(|f| f.path.clone()))
            .collect();
        if let Ok(removed) = db::prune_missing(folder_id, source_type, &prune_prefixes, &kept) {
            if removed > 0 {
                let _ = db::delete_empty_anime();
                emit(
                    "scanning",
                    total,
                    total,
                    &format!("清理 {removed} 个失效文件"),
                );
            }
        }
    }

    Ok(())
}

/// Match only after all folders have been scanned. Three consecutive Bangumi
/// errors trip a circuit breaker so a disconnected API cannot add 30 seconds
/// of timeout to every unmatched title.
fn finish_scan_session(sink: &StreamSink<ScanProgress>) -> Result<(), String> {
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }
    let unmatched = db::unmatched_anime().map_err(|e| e.to_string())?;
    let match_total = unmatched.len() as i64;
    let done = std::sync::atomic::AtomicI64::new(0);
    let consecutive_errors = std::sync::atomic::AtomicI64::new(0);
    let total_errors = std::sync::atomic::AtomicI64::new(0);

    RT.block_on(async {
        use futures::stream::{self, StreamExt};
        stream::iter(unmatched)
            // Bounded concurrency: parallel matching speeds up large scans, but
            // Bangumi rate-limits, and a 429 on the full-title query degrades
            // match quality — 4 is the sweet spot (via the mainland mirror).
            .for_each_concurrent(4, |(anime_id, title)| {
                let done = &done;
                let consecutive_errors = &consecutive_errors;
                let total_errors = &total_errors;
                async move {
                    if scan_control::is_cancelled()
                        || consecutive_errors.load(std::sync::atomic::Ordering::Relaxed) >= 3
                    {
                        return;
                    }
                    let result = tokio::select! {
                        result = tokio::time::timeout(
                            std::time::Duration::from_secs(20),
                            bangumi::best_match(&title),
                        ) => result.unwrap_or_else(|_| {
                            Err(anyhow::anyhow!("Bangumi 单个标题匹配超过 20 秒"))
                        }),
                        _ = scan_control::wait_cancelled() => return,
                    };
                    match &result {
                        Ok(_) => {
                            consecutive_errors.store(0, std::sync::atomic::Ordering::Relaxed);
                        }
                        Err(_) => {
                            consecutive_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            total_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                    }
                    if scan_control::is_cancelled() {
                        return;
                    }
                    if let Ok(Some(best)) = result {
                        // Search results often lack images/eps; fetch the
                        // subject detail to get a reliable cover, rating, tags.
                        let detail = tokio::select! {
                            result = bangumi::subject(best.id) => result.ok(),
                            _ = scan_control::wait_cancelled() => return,
                        };
                        let cover = detail
                            .as_ref()
                            .and_then(|d| d.cover_url.clone())
                            .or(best.cover_url.clone());
                        let eps = detail.as_ref().and_then(|d| d.eps).or(best.eps);
                        let summary = detail
                            .as_ref()
                            .map(|d| d.summary.clone())
                            .filter(|s| !s.is_empty())
                            .unwrap_or(best.summary.clone());
                        let rating = detail.as_ref().and_then(|d| d.rating).or(best.rating);
                        let rating_total = detail
                            .as_ref()
                            .and_then(|d| d.rating_total)
                            .or(best.rating_total);
                        let rating_rank = detail
                            .as_ref()
                            .and_then(|d| d.rating_rank)
                            .or(best.rating_rank);
                        let rating_counts = detail
                            .as_ref()
                            .and_then(|d| d.rating_counts.clone())
                            .or(best.rating_counts.clone());
                        let air_date = detail
                            .as_ref()
                            .and_then(|d| d.air_date.clone())
                            .or(best.air_date.clone());
                        let (tags_vec, tag_counts) = detail
                            .as_ref()
                            .filter(|subject| !subject.tags.is_empty())
                            .map(|subject| (subject.tags.clone(), subject.tag_counts.clone()))
                            .unwrap_or((best.tags.clone(), best.tag_counts.clone()));
                        let tags = if tags_vec.is_empty() {
                            None
                        } else {
                            Some(tags_vec.join(","))
                        };
                        let weekday = air_date.as_deref().and_then(bangumi::weekday_of);
                        let _ = db::bind_bangumi(
                            anime_id,
                            best.id,
                            &best.name,
                            &best.name_cn,
                            &summary,
                            cover.as_deref(),
                            air_date.as_deref(),
                            eps,
                            rating,
                            rating_total,
                            rating_rank,
                            rating_counts.as_deref(),
                            weekday,
                            tags.as_deref(),
                            tag_counts.as_deref(),
                            "high",
                            false,
                        );
                    }
                    let n = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                    let _ = sink.add(ScanProgress {
                        stage: "matching".to_string(),
                        current: n,
                        total: match_total,
                        message: title,
                    });
                }
            })
            .await;
    });
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }

    // Different sources of the same show can still have distinct filenames.
    // titles) can land in separate rows that both matched the same subject —
    // fold them into one entry; episodes keep their release_group label.
    let _ = db::merge_duplicate_bindings();

    let api_unreachable = consecutive_errors.load(std::sync::atomic::Ordering::Relaxed) >= 3;

    // 3b. Re-apply manual per-file matches from the per-folder sidecars: the
    // scanner just re-grouped every file by filename, so any file the user
    // hand-matched (or detached) needs to be pulled back onto its chosen
    // subject. Runs last so it always wins, and reads the `.kurako-match.json`
    // sidecars that live IN the media folders (durable across a full
    // clear+rescan, which drops the whole episodes table).
    for source_type in ["local", "saf", "smb", "webdav"] {
        apply_sidecars(source_type, !api_unreachable);
        if scan_control::is_cancelled() {
            return Err("扫描已取消".to_string());
        }
    }
    // Also re-apply the app-data fallback store (read-only SMB + SAF matches):
    // keyed by full file path and source-agnostic, so one call covers all.
    apply_fallback(!api_unreachable);
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }

    // 4. With an access token, mark which entries the user has collected on
    // Bangumi so the UI can pin them.
    let collection_error = if api_unreachable {
        None
    } else {
        sync_collections_inner(true).err()
    };
    if scan_control::is_cancelled() {
        return Err("扫描已取消".to_string());
    }

    let failed = total_errors.load(std::sync::atomic::Ordering::Relaxed);
    if api_unreachable || failed > 0 || collection_error.is_some() {
        let detail = if failed > 0 {
            format!("（已连续失败，累计 {failed} 次请求错误）")
        } else {
            String::new()
        };
        let reason = if api_unreachable {
            "长时间无法连接 Bangumi API"
        } else {
            "Bangumi API 请求失败"
        };
        let _ = sink.add(ScanProgress {
            stage: "warning".to_string(),
            current: done.load(std::sync::atomic::Ordering::Relaxed),
            total: match_total,
            message: format!("媒体扫描已完成，但{reason}，部分自动匹配与收藏同步未完成{detail}"),
        });
    } else {
        let _ = sink.add(ScanProgress {
            stage: "done".to_string(),
            current: match_total,
            total: match_total,
            message: "完成".to_string(),
        });
    }
    Ok(())
}

fn sync_collections_inner(cancel_with_scan: bool) -> Result<u32, String> {
    if !bangumi::has_token() {
        return Ok(0);
    }
    // Bulk-fetch all collections in one paginated sweep instead of polling
    // each subject individually — dramatically fewer requests and no rate-limit
    // risk on large libraries.
    let all = RT
        .block_on(async {
            if cancel_with_scan {
                tokio::select! {
                    result = bangumi::all_collections() => result,
                    _ = scan_control::wait_cancelled() => {
                        Err(anyhow::anyhow!("扫描已取消"))
                    }
                }
            } else {
                bangumi::all_collections().await
            }
        })
        .map_err(|e| e.to_string())?;

    if all.is_empty() {
        return Ok(0);
    }

    // Build a map from subject_id -> collection_type.
    let map: std::collections::HashMap<i64, i64> = all.into_iter().collect();

    // Apply to every locally-bound anime; subjects absent from the map are
    // marked 0 (uncollected).
    let bound = db::bound_anime().map_err(|e| e.to_string())?;
    let mut updated = 0u32;
    for (anime_id, subject_id) in &bound {
        if cancel_with_scan && scan_control::is_cancelled() {
            return Err("扫描已取消".to_string());
        }
        let kind = *map.get(subject_id).unwrap_or(&0);
        let _ = db::set_collection(*anime_id, kind);
        updated += 1;
    }
    Ok(updated)
}

/// Refresh Bangumi collection status (想看/在看/看过…) for every bound entry.
/// Uses a single paginated bulk-fetch — safe to call frequently.
/// Returns the number of entries updated.
pub fn sync_collections() -> Result<u32, String> {
    sync_collections_inner(false)
}

/// Update the user's Bangumi collection type for one anime entry, then persist
/// locally so the library immediately reflects the change.
/// collection_type: 1=想看, 2=看过, 3=在看, 4=搁置, 5=抛弃.
/// Bangumi only accepts 1..=5; there is no "uncollect" via this endpoint.
pub fn set_collection(anime_id: i64, collection_type: i64) -> Result<(), String> {
    if !(1..=5).contains(&collection_type) {
        return Err(format!(
            "invalid collection type {collection_type} (must be 1..=5)"
        ));
    }
    // Look up the subject_id for this anime.
    let anime = db::get_anime(anime_id)
        .map_err(|e| e.to_string())?
        .ok_or("anime not found")?;
    let subject_id = anime.bangumi_id.ok_or("not yet matched to Bangumi")?;
    if bangumi::has_token() {
        RT.block_on(async { bangumi::update_collection(subject_id, collection_type).await })
            .map_err(|e| e.to_string())?;
    }
    db::set_collection(anime_id, collection_type).map_err(|e| e.to_string())
}

/// Clear the collection mark for one anime *locally only*. Bangumi's public API
/// has no endpoint to remove a subject collection (the v0 route only supports
/// GET/PATCH/POST, no DELETE), so this cannot un-collect on the website — it
/// just drops the local pin/badge. The Dart side surfaces that caveat to the
/// user.
pub fn clear_collection(anime_id: i64) -> Result<(), String> {
    db::set_collection(anime_id, 0).map_err(|e| e.to_string())
}

/// Clear the incremental-scan badge after the user has opened this anime.
pub fn clear_anime_new_files(anime_id: i64) -> Result<(), String> {
    db::clear_anime_has_new_files(anime_id).map_err(|e| e.to_string())
}

/// Re-fetch subject metadata (rating, tags, cover, episode titles) for a
/// single already-bound anime. Use this instead of a full rescan to pick up
/// rating updates or newly-published episode names.
pub fn refresh_metadata(anime_id: i64) -> Result<(), String> {
    let anime = db::get_anime(anime_id)
        .map_err(|e| e.to_string())?
        .ok_or("anime not found")?;
    let subject_id = anime.bangumi_id.ok_or("not yet matched to Bangumi")?;
    RT.block_on(async { refresh_one(anime_id, subject_id, anime.corrected).await })
        .map_err(|e| e.to_string())
}

/// Re-fetch and rebind one subject's metadata + episode titles. Shared by the
/// single-anime [refresh_metadata] and the startup bulk [refresh_all_metadata].
async fn refresh_one(anime_id: i64, subject_id: i64, corrected: bool) -> anyhow::Result<()> {
    let s = bangumi::subject(subject_id).await?;
    let tags = if s.tags.is_empty() {
        None
    } else {
        Some(s.tags.join(","))
    };
    let weekday = s.air_date.as_deref().and_then(bangumi::weekday_of);
    db::bind_bangumi(
        anime_id,
        s.id,
        &s.name,
        &s.name_cn,
        &s.summary,
        s.cover_url.as_deref(),
        s.air_date.as_deref(),
        s.eps,
        s.rating,
        s.rating_total,
        s.rating_rank,
        s.rating_counts.as_deref(),
        weekday,
        tags.as_deref(),
        s.tag_counts.as_deref(),
        "high",
        corrected,
    )?;
    // Enrich on-disk episodes with Bangumi episode titles (only fills NULL
    // titles; never overwrites user-visible data).
    if let Ok(titles) = bangumi::subject_episode_titles(subject_id, 500).await {
        for t in titles {
            let title = if !t.name_cn.is_empty() {
                &t.name_cn
            } else {
                &t.name
            };
            if !title.is_empty() {
                db::set_episode_title(anime_id, t.ep, title)?;
            }
        }
    }
    Ok(())
}

/// Refresh Bangumi metadata for EVERY bound anime, concurrently (bounded).
///
/// Called once per app launch (from Dart's startup) so ratings/summaries/tags/
/// episode titles across the whole library stay current — replacing the old
/// per-anime "refresh the first time you open each subject" behaviour, which
/// re-hit the API on every browse. Bounded parallelism keeps it fast without
/// tripping Bangumi's rate limiter. Returns the number of entries refreshed.
pub fn refresh_all_metadata() -> Result<i64, String> {
    let bound = db::bound_anime().map_err(|e| e.to_string())?;
    if bound.is_empty() {
        return Ok(0);
    }
    let done = std::sync::atomic::AtomicI64::new(0);
    RT.block_on(async {
        use futures::stream::{self, StreamExt};
        stream::iter(bound)
            .for_each_concurrent(4, |(anime_id, subject_id)| {
                let done = &done;
                async move {
                    // `corrected` guards a user-fixed match; preserve it.
                    let corrected = db::get_anime(anime_id)
                        .ok()
                        .flatten()
                        .map(|a| a.corrected)
                        .unwrap_or(false);
                    if refresh_one(anime_id, subject_id, corrected).await.is_ok() {
                        done.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                }
            })
            .await;
    });
    Ok(done.load(std::sync::atomic::Ordering::Relaxed))
}

/// Clear all recognised anime and episodes (keeps library folders). Use before
/// a fresh scan to rebuild the library from scratch.
pub fn clear_library() -> Result<(), String> {
    db::clear_all().map_err(|e| e.to_string())
}

// ---- Blacklist ----

/// Block an anime (kind "anime", value = title_raw) or a single video file
/// (kind "file", value = file_path). Matching library rows are removed
/// immediately and the scanner skips blocked items on every future scan.
pub fn add_blacklist(kind: String, value: String) -> Result<(), String> {
    db::add_blacklist(&kind, &value, now_secs()).map_err(|e| e.to_string())
}

pub fn list_blacklist() -> Result<Vec<BlacklistEntry>, String> {
    db::list_blacklist().map_err(|e| e.to_string())
}

/// Unblock an entry. The item reappears after the next rescan.
pub fn remove_blacklist(id: i64) -> Result<(), String> {
    db::remove_blacklist(id).map_err(|e| e.to_string())
}

// ---- Manual correction ----

/// Search Bangumi for candidates to show in the correction dialog.
pub fn search_bangumi(keyword: String) -> Result<Vec<BangumiSubject>, String> {
    RT.block_on(async {
        // Same fallback as auto-match: v0 misses many CJK keywords that the
        // legacy endpoint still finds.
        match bangumi::search(&keyword, 10).await {
            Ok(hits) if !hits.is_empty() => Ok(hits),
            _ => bangumi::search_legacy(&keyword, 10).await,
        }
    })
    .map_err(|e| e.to_string())
}

/// Bind an anime to a chosen Bangumi subject (manual correction). Returns the
/// id of the entry that survives — a re-match can point this entry at a subject
/// another entry already holds, and the merge below folds the smaller into the
/// larger, DELETING one of them. The detail page navigates to the returned id
/// so it never strands the user on a now-deleted (null) entry — the old bug
/// behind the bare "未找到" screen.
fn store_subject_binding(
    anime_id: i64,
    subject: &BangumiSubject,
    corrected: bool,
) -> Result<(), String> {
    let tags = if subject.tags.is_empty() {
        None
    } else {
        Some(subject.tags.join(","))
    };
    let weekday = subject.air_date.as_deref().and_then(bangumi::weekday_of);
    db::bind_bangumi(
        anime_id,
        subject.id,
        &subject.name,
        &subject.name_cn,
        &subject.summary,
        subject.cover_url.as_deref(),
        subject.air_date.as_deref(),
        subject.eps,
        subject.rating,
        subject.rating_total,
        subject.rating_rank,
        subject.rating_counts.as_deref(),
        weekday,
        tags.as_deref(),
        subject.tag_counts.as_deref(),
        "high",
        corrected,
    )
    .map_err(|e| e.to_string())
}

fn binding_survivor(anime_id: i64, bangumi_id: i64) -> Result<i64, String> {
    let _ = db::merge_duplicate_bindings();
    Ok(db::anime_id_for_bangumi(bangumi_id)
        .map_err(|e| e.to_string())?
        .unwrap_or(anime_id))
}

pub fn bind_anime(anime_id: i64, bangumi_id: i64) -> Result<i64, String> {
    let subject = RT
        .block_on(async { bangumi::subject(bangumi_id).await })
        .map_err(|e| e.to_string())?;
    store_subject_binding(anime_id, &subject, true)?;
    // The user's collection status for the newly bound subject.
    if bangumi::has_token() {
        if let Ok(c) = RT.block_on(async { bangumi::collection_status(bangumi_id).await }) {
            let _ = db::set_collection(anime_id, c.unwrap_or(0));
        }
    }
    // Manual re-match can point this entry at a subject another entry already
    // has — fold them together like the auto-matcher does, then report whichever
    // row survived so the caller can navigate there.
    let survivor = binding_survivor(anime_id, bangumi_id)?;
    // Persist this whole-anime match so a rescan keeps every file of the entry on
    // this subject (the detail page's top-right 重新匹配 uses this path). Write a
    // sidecar/fallback entry for each of the survivor's files. New per-file
    // pinned entries created by ensure_anime_for_subject have no episodes yet, so
    // this loop is a harmless no-op for them.
    if let Ok(episodes) = db::list_episodes(survivor) {
        for ep in &episodes {
            persist_match(&ep.file_path, bangumi_id);
        }
    }
    Ok(survivor)
}

/// Scan-only binding path. Every network wait races the shared scan cancel
/// signal, while the interactive manual-match path above retains its existing
/// behavior outside a scan session.
fn bind_anime_during_scan(anime_id: i64, bangumi_id: i64) -> Result<i64, String> {
    let subject = RT.block_on(async {
        tokio::select! {
            result = bangumi::subject(bangumi_id) => Some(result),
            _ = scan_control::wait_cancelled() => None,
        }
    });
    let Some(subject) = subject else {
        return Err("扫描已取消".to_string());
    };
    let subject = subject.map_err(|e| e.to_string())?;
    store_subject_binding(anime_id, &subject, true)?;

    if bangumi::has_token() {
        let status = RT.block_on(async {
            tokio::select! {
                result = bangumi::collection_status(bangumi_id) => Some(result),
                _ = scan_control::wait_cancelled() => None,
            }
        });
        let Some(status) = status else {
            return Err("扫描已取消".to_string());
        };
        if let Ok(collection) = status {
            let _ = db::set_collection(anime_id, collection.unwrap_or(0));
        }
    }
    binding_survivor(anime_id, bangumi_id)
}

fn ensure_anime_for_subject(bangumi_id: i64, file_path: &str) -> Result<i64, String> {
    match db::anime_id_for_bangumi(bangumi_id).map_err(|e| e.to_string())? {
        Some(id) => Ok(id),
        None => {
            let key = format!("pinned:{file_path}");
            let new_id = db::upsert_anime(&key, file_path).map_err(|e| e.to_string())?;
            bind_anime(new_id, bangumi_id)
        }
    }
}

/// Manually bind ONE video file to a Bangumi subject, splitting it out of its
/// (mis-grouped) anime into the right entry. The match is persisted next to the
/// media (a `.kurako-match.json` sidecar) when the folder is writable, else in
/// the app's fallback config — either way it survives ANY rescan, including
/// "清空并重新扫描" which drops the whole episodes table. Returns the id of the
/// anime the file now belongs to. Fixes files a wrong filename lumped into the
/// wrong show.
pub fn match_episode(episode_id: i64, bangumi_id: i64) -> Result<i64, String> {
    let file_path = db::episode_file_path(episode_id)
        .map_err(|e| e.to_string())?
        .ok_or("episode not found")?;
    persist_match(&file_path, bangumi_id);
    let anime_id = ensure_anime_for_subject(bangumi_id, &file_path)?;
    db::move_episode_to_anime(episode_id, anime_id).map_err(|e| e.to_string())?;
    // The file may have left an empty anime behind (its group's last episode);
    // clean it up so the library doesn't keep a ghost entry.
    let _ = db::delete_empty_anime();
    Ok(anime_id)
}

/// Detach a single file from its current anime into the 未分类 bucket, recording
/// a `DETACHED` entry so a rescan keeps it out of any show. For a file a wrong
/// filename wrongly grouped, when the user just wants it gone from this entry
/// without matching it to anything. Returns the 未分类 anime id.
pub fn detach_episode(episode_id: i64) -> Result<i64, String> {
    let file_path = db::episode_file_path(episode_id)
        .map_err(|e| e.to_string())?
        .ok_or("episode not found")?;
    persist_match(&file_path, sidecar::DETACHED);
    let misc_id = db::upsert_anime("__misc__", "未分类").map_err(|e| e.to_string())?;
    db::move_episode_to_anime(episode_id, misc_id).map_err(|e| e.to_string())?;
    let _ = db::delete_empty_anime();
    Ok(misc_id)
}

/// Persist `file_path -> bangumi_id` so a rescan re-applies it. Best-effort and
/// silent: the primary target is a `.kurako-match.json` sidecar IN the file's
/// folder (durable + travels with the media); when that folder can't be written
/// — a read-only SMB share, or Android SAF (Rust can't write content://) — it
/// falls back to a single `match_fallback.json` in the app data directory, which
/// is always writable. Either way the match is preserved, so no warning is
/// surfaced to the UI.
fn persist_match(file_path: &str, bangumi_id: i64) {
    let Some((parent, name)) = sidecar::split_parent_name(file_path) else {
        // No resolvable folder — keep it in the always-writable fallback.
        let _ = sidecar::set_fallback(file_path, bangumi_id);
        return;
    };
    match sidecar::source_of(&parent) {
        sidecar::Source::Local => {
            let mut map = sidecar::read_local(&parent);
            map.insert(name, bangumi_id);
            if sidecar::write_local(&parent, &map).is_err() {
                let _ = sidecar::set_fallback(file_path, bangumi_id);
            }
        }
        sidecar::Source::Smb => {
            let wrote = RT.block_on(async {
                // A failed read must NOT degrade to an empty map: writing that
                // back would overwrite the sidecar and wipe every existing
                // manual match in the folder. read_sidecar only returns an
                // empty map for a confirmed-absent file; on transport errors
                // it fails, and this match lands in the app fallback below.
                let mut map = smb::read_sidecar(&parent).await?;
                map.insert(name, bangumi_id);
                smb::write_sidecar(&parent, &map).await
            });
            // Read-only share → keep it in the app fallback instead.
            if wrote.is_err() {
                let _ = sidecar::set_fallback(file_path, bangumi_id);
            }
        }
        // SAF content:// can't be written from Rust — always use the fallback.
        sidecar::Source::Saf | sidecar::Source::Remote => {
            let _ = sidecar::set_fallback(file_path, bangumi_id);
        }
    }
}

/// The anime entry a subject should live in: reuse an existing bound entry, else
/// make a fresh per-file group (unique group_key from the file path so nothing
/// else joins it) and bind it. Shared by the manual match and the post-scan
/// sidecar re-apply.
fn ensure_anime_for_subject_during_scan(
    bangumi_id: i64,
    file_path: &str,
    allow_network_binding: bool,
) -> Result<i64, String> {
    match db::anime_id_for_bangumi(bangumi_id).map_err(|e| e.to_string())? {
        Some(id) => Ok(id),
        None if !allow_network_binding => Err("Bangumi API 当前不可用".to_string()),
        None => {
            let key = format!("pinned:{file_path}");
            let new_id = db::upsert_anime(&key, file_path).map_err(|e| e.to_string())?;
            match bind_anime_during_scan(new_id, bangumi_id) {
                Ok(id) => Ok(id),
                Err(error) => {
                    let _ = db::delete_empty_anime();
                    Err(error)
                }
            }
        }
    }
}

/// Route a single `file_path -> bangumi_id` decision to the right anime entry
/// (existing subject / fresh pinned entry / 未分类 for DETACHED) if the file is
/// currently in the library. Shared by both re-apply passes below.
fn apply_one(file_path: &str, bangumi_id: i64, allow_network_binding: bool) {
    match db::episode_exists(file_path) {
        Ok(true) => {}
        _ => return,
    }
    let target = if bangumi_id == sidecar::DETACHED {
        db::upsert_anime("__misc__", "未分类").ok()
    } else {
        ensure_anime_for_subject_during_scan(bangumi_id, file_path, allow_network_binding).ok()
    };
    if let Some(anime_id) = target {
        let _ = db::move_episode_by_path(file_path, anime_id);
    }
}

/// Re-apply the app-data fallback store (read-only SMB / SAF matches) after a
/// scan. Keyed by full file locator, source-agnostic, so it's read ONCE per scan
/// regardless of source_type. Best-effort.
fn apply_fallback(allow_network_binding: bool) {
    let map = sidecar::read_fallback();
    if map.is_empty() {
        return;
    }
    for (file_path, bangumi_id) in map {
        if scan_control::is_cancelled() {
            return;
        }
        apply_one(&file_path, bangumi_id, allow_network_binding);
    }
    if !scan_control::is_cancelled() {
        let _ = db::delete_empty_anime();
    }
}

/// Re-apply every manual per-file match after a scan by reading the
/// `.kurako-match.json` sidecar of each folder that currently has episodes. For
/// each `file_name -> bangumi_id` entry whose file is present, move it under the
/// right (existing or freshly bound) subject — or into 未分类 for a `DETACHED`
/// entry — undoing whatever grouping the scanner just did for that file.
/// Best-effort: a missing/corrupt sidecar or one bad entry never aborts the scan
/// tail. `source_type` selects local vs SMB sidecar I/O (SAF is never written,
/// so it has no sidecars to read).
fn apply_sidecars(source_type: &str, allow_network_binding: bool) {
    // Distinct folders currently holding episodes of this source; each may carry
    // a sidecar. `episode_parents` returns the folder locator + a present file
    // name so we can rebuild absolute file paths without re-deriving separators.
    let folders = match db::episode_parents(source_type) {
        Ok(f) => f,
        Err(_) => return,
    };
    for parent in folders {
        if scan_control::is_cancelled() {
            return;
        }
        let map = match source_type {
            "smb" => {
                let result = RT.block_on(async {
                    tokio::select! {
                        result = smb::read_sidecar(&parent) => Some(result),
                        _ = scan_control::wait_cancelled() => None,
                    }
                });
                let Some(result) = result else {
                    return;
                };
                result.unwrap_or_default()
            }
            "local" => sidecar::read_local(&parent),
            // SAF sidecars are never written, so nothing to read.
            _ => continue,
        };
        if map.is_empty() {
            continue;
        }
        for (name, bangumi_id) in map {
            if scan_control::is_cancelled() {
                return;
            }
            let file_path = match sidecar::source_of(&parent) {
                sidecar::Source::Local => std::path::Path::new(&parent)
                    .join(&name)
                    .to_string_lossy()
                    .to_string(),
                _ => format!("{parent}/{name}"),
            };
            apply_one(&file_path, bangumi_id, allow_network_binding);
        }
    }
    if !scan_control::is_cancelled() {
        let _ = db::delete_empty_anime();
    }
}

/// Remove ALL manual-match configuration and the current recognition index.
/// Sources, downloads, blacklist, account and settings stay intact; the next
/// scan rebuilds anime/episodes with automatic grouping and matching.
pub fn clear_match_config() -> Result<u32, String> {
    let mut removed = 0u32;
    // Local sidecars.
    let local_parents =
        db::episode_parents("local").map_err(|error| format!("读取本地剧集目录失败：{error}"))?;
    for parent in local_parents {
        let p = std::path::Path::new(&parent).join(sidecar::SIDECAR_NAME);
        match std::fs::remove_file(&p) {
            Ok(()) => removed += 1,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!("删除本地手动匹配配置失败：{error}"));
            }
        }
    }
    // SMB sidecars. Read first so a read-only folder with no sidecar remains a
    // normal no-op, while a transport failure or an undeletable real sidecar
    // is surfaced instead of falsely claiming the reset succeeded.
    let smb_parents =
        db::episode_parents("smb").map_err(|error| format!("读取 SMB 剧集目录失败：{error}"))?;
    for parent in smb_parents {
        let map = RT
            .block_on(async { smb::read_sidecar(&parent).await })
            .map_err(|error| format!("读取 SMB 手动匹配配置失败：{error:#}"))?;
        if map.is_empty() {
            continue;
        }
        if RT
            .block_on(async { smb::delete_sidecar(&parent).await })
            .map_err(|error| format!("删除 SMB 手动匹配配置失败：{error:#}"))?
        {
            removed += 1;
        }
    }
    // App-data fallback (read-only SMB + all SAF matches live here).
    if sidecar::remove_all_fallback()
        .map_err(|error| format!("删除软件内手动匹配配置失败：{error}"))?
    {
        removed += 1;
    }
    db::clear_all().map_err(|error| format!("清空当前识别结果失败：{error}"))?;
    Ok(removed)
}

#[cfg(test)]
mod download_path_tests {
    use super::*;

    #[test]
    fn cross_source_local_copy_requires_the_recorded_byte_size() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "kurako-download-match-{}-{nonce}.mkv",
            std::process::id()
        ));
        std::fs::write(&path, b"12345").unwrap();
        let local_path = path.to_string_lossy().to_string();

        assert!(download_match_is_valid(&db::DownloadPathMatch {
            local_path: local_path.clone(),
            bytes_total: 5,
            exact_uri: false,
        }));
        assert!(!download_match_is_valid(&db::DownloadPathMatch {
            local_path: local_path.clone(),
            bytes_total: 4,
            exact_uri: false,
        }));
        // Exact URI behavior stays compatible: a non-empty local file remains
        // authoritative even when a legacy record has no reliable byte count.
        assert!(download_match_is_valid(&db::DownloadPathMatch {
            local_path,
            bytes_total: 0,
            exact_uri: true,
        }));

        std::fs::remove_file(path).unwrap();
    }
}
