use crate::models::{
    Anime, BangumiSubject, BlacklistEntry, DownloadEntry, DownloadProgress, Episode,
    LibraryFolder, ScanProgress, SubtitleCandidate,
};
use crate::{bangumi, db, scan, smb};
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;

static RT: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime")
});

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Open (and create if needed) the SQLite database at the given path.
pub fn init_db(db_path: String) -> Result<(), String> {
    db::init(&db_path).map_err(|e| e.to_string())
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
    Ok(LibraryFolder {
        id,
        path,
        added_at: now_secs(),
        last_scanned: None,
        source_type,
    })
}

pub fn remove_library_folder(id: i64) -> Result<(), String> {
    db::remove_folder(id).map_err(|e| e.to_string())
}

pub fn list_library_folders() -> Result<Vec<LibraryFolder>, String> {
    db::list_folders().map_err(|e| e.to_string())
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

// ---- Playback progress ----

pub fn update_progress(episode_id: i64, position_ms: i64, duration_ms: i64) -> Result<(), String> {
    db::update_progress(episode_id, position_ms, duration_ms).map_err(|e| e.to_string())
}

pub fn set_watched(episode_id: i64, watched: bool) -> Result<(), String> {
    db::set_watched(episode_id, watched).map_err(|e| e.to_string())
}

// ---- Scan + auto-match (streams progress back to Dart) ----

/// Scan all library folders, group files into anime, then auto-match each new
/// anime against Bangumi. Emits ScanProgress events throughout.
///
/// When `incremental` is true, folders whose newest file/dir mtime is older than
/// their last recorded scan time are skipped entirely — dramatically faster on
/// large libraries where only a few folders changed.
pub fn scan_and_match(sink: StreamSink<ScanProgress>, incremental: bool) -> Result<(), String> {
    let folders = db::list_folders().map_err(|e| e.to_string())?;

    let emit = |stage: &str, current: i64, total: i64, message: &str, sink: &StreamSink<ScanProgress>| {
        let _ = sink.add(ScanProgress {
            stage: stage.to_string(),
            current,
            total,
            message: message.to_string(),
        });
    };

    // 1. Group video files by folder into anime, then upsert. Skip unchanged
    //    folders when doing an incremental scan. `scanned_prefixes` records the
    //    folders actually walked, so pruning only deletes missing files within
    //    them (a skipped folder's still-present episodes are never touched).
    let mut groups = Vec::new();
    let mut scanned_prefixes: Vec<String> = Vec::new();
    for f in &folders {
        // Only walkdir-scannable local folders are handled here; SAF folders are
        // enumerated on the Dart side and go through scan_files_and_match.
        if f.source_type != "local" {
            continue;
        }
        let mtime = scan::folder_max_mtime(&f.path);
        if incremental {
            if let Some(last) = f.last_scanned {
                if mtime > 0 && mtime <= last {
                    emit("scanning", 0, 0, &format!("跳过未改动 {}", f.path), &sink);
                    continue;
                }
            }
        }
        emit("scanning", 0, 0, &format!("扫描 {}", f.path), &sink);
        groups.extend(scan::group_library(&f.path));
        scanned_prefixes.push(f.path.clone());
        // Record the scan time so the next incremental run can skip it.
        let _ = db::set_folder_scanned(f.id, now_secs());
    }

    finish_scan(groups, "local", scanned_prefixes, &sink)
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
    let scanned: Vec<scan::ScannedFile> = files
        .into_iter()
        .map(|f| scan::ScannedFile {
            uri: f.uri,
            file_name: f.file_name,
            relative_parent: f.relative_parent,
        })
        .collect();
    let groups = scan::group_files(scanned);
    let _ = db::set_folder_scanned(folder_id, now_secs());
    // Scope deletion-pruning to this folder's locator prefix so files removed
    // from the SMB share / SAF tree are dropped from the library too.
    let prefixes = prune_prefixes_for(folder_id, &source_type);
    finish_scan(groups, &source_type, prefixes, &sink)
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

/// Restore cached SMB credentials on startup (from Dart's persisted settings)
/// without a network round-trip. Connection is opened lazily per operation.
pub fn smb_set_credentials(host: String, share: String, user: String, password: String) {
    smb::set_creds(Some(smb::SmbCreds {
        addr: if host.contains(':') { host } else { format!("{host}:445") },
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

/// Cumulative bytes streamed by the SMB proxy. Dart polls this once a second
/// and shows the delta as transfer speed in the playback-info panel.
pub fn smb_proxy_stats() -> u64 {
    smb::proxy_bytes_served()
}

// ---- SMB downloads ----

/// Download an SMB file to `dest_dir`, streaming progress. On success the
/// download is recorded so playback prefers the local copy from then on.
pub fn smb_download(
    sink: StreamSink<DownloadProgress>,
    smb_uri: String,
    dest_dir: String,
) -> Result<String, String> {
    let local = RT
        .block_on(async {
            smb::download(&smb_uri, &dest_dir, |done, total| {
                let _ = sink.add(DownloadProgress {
                    bytes_done: done as i64,
                    bytes_total: total as i64,
                });
            })
            .await
        })
        .map_err(|e| e.to_string())?;
    let size = std::fs::metadata(&local).map(|m| m.len() as i64).unwrap_or(0);
    db::add_download(&smb_uri, &local, size, now_secs()).map_err(|e| e.to_string())?;
    Ok(local)
}

/// Cancel one in-flight download by its SMB URI (checked between 1MB chunks;
/// other concurrent downloads are unaffected).
pub fn smb_cancel_download(smb_uri: String) {
    smb::cancel_download(&smb_uri);
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
        let _ = std::fs::remove_file(p);
    }
    Ok(())
}

/// The local copy of an SMB file if it was downloaded and still exists on disk
/// (a stale record whose file vanished is cleaned up and returns None).
pub fn downloaded_local_path(smb_uri: String) -> Result<Option<String>, String> {
    let path = db::download_local_path(&smb_uri).map_err(|e| e.to_string())?;
    match path {
        Some(p) if std::path::Path::new(&p).exists() => Ok(Some(p)),
        Some(_) => {
            // File was deleted outside the app — drop the stale record.
            if let Ok(list) = db::list_downloads() {
                for d in list {
                    if d.smb_uri == smb_uri {
                        let _ = db::remove_download(d.id);
                    }
                }
            }
            Ok(None)
        }
        None => Ok(None),
    }
}

// ---- Snapshot sync (multi-device) ----
// Removed: SMB snapshots proved impractical (a snapshot from one device
// references that device's SMB path, and a restoring device that isn't
// connected to that same share can't play the entries).

/// Shared tail of a scan: upsert groups/episodes, auto-match against Bangumi,
/// merge duplicate bindings, sync collection status, emit done.
fn finish_scan(
    groups: Vec<scan::AnimeGroup>,
    source_type: &str,
    prune_prefixes: Vec<String>,
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
        let anime_id = db::upsert_anime(&g.group_key, &g.title).map_err(|e| e.to_string())?;
        for ff in &g.files {
            db::upsert_episode(
                anime_id,
                &ff.path,
                &ff.file_name,
                ff.parsed.episode_no,
                ff.parsed.resolution.as_deref(),
                ff.parsed.release_group.as_deref(),
                source_type,
            )
            .map_err(|e| e.to_string())?;
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
        if let Ok(removed) = db::prune_missing(source_type, &prune_prefixes, &kept) {
            if removed > 0 {
                let _ = db::delete_empty_anime();
                emit("scanning", total, total, &format!("清理 {removed} 个失效文件"));
            }
        }
    }

    // 2. Auto-match unmatched anime against Bangumi, concurrently (bounded).
    let unmatched = db::unmatched_anime().map_err(|e| e.to_string())?;
    let match_total = unmatched.len() as i64;
    let done = std::sync::atomic::AtomicI64::new(0);

    RT.block_on(async {
        use futures::stream::{self, StreamExt};
        stream::iter(unmatched)
            // Bounded concurrency: parallel matching speeds up large scans, but
            // Bangumi rate-limits, and a 429 on the full-title query degrades
            // match quality — 4 is the sweet spot (via the mainland mirror).
            .for_each_concurrent(4, |(anime_id, title)| {
                let done = &done;
                async move {
                    if let Ok(Some(best)) = bangumi::best_match(&title).await {
                        // Search results often lack images/eps; fetch the
                        // subject detail to get a reliable cover, rating, tags.
                        let detail = bangumi::subject(best.id).await.ok();
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
                        let tags_vec = detail
                            .as_ref()
                            .map(|d| d.tags.clone())
                            .filter(|t| !t.is_empty())
                            .unwrap_or(best.tags.clone());
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

    // 3. Different sources of the same show (fansub A + fansub B, romaji vs CJK
    // titles) can land in separate rows that both matched the same subject —
    // fold them into one entry; episodes keep their release_group label.
    let _ = db::merge_duplicate_bindings();

    // 4. With an access token, mark which entries the user has collected on
    // Bangumi so the UI can pin them.
    let _ = sync_collections_inner();

    emit("done", total, total, "完成");
    Ok(())
}

fn sync_collections_inner() -> Result<u32, String> {
    if !bangumi::has_token() {
        return Ok(0);
    }
    // Bulk-fetch all collections in one paginated sweep instead of polling
    // each subject individually — dramatically fewer requests and no rate-limit
    // risk on large libraries.
    let all = RT
        .block_on(async { bangumi::all_collections().await })
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
    sync_collections_inner()
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
        RT.block_on(async {
            bangumi::update_collection(subject_id, collection_type).await
        })
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
    let tags = if s.tags.is_empty() { None } else { Some(s.tags.join(",")) };
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
        "high",
        corrected,
    )?;
    // Enrich on-disk episodes with Bangumi episode titles (only fills NULL
    // titles; never overwrites user-visible data).
    if let Ok(titles) = bangumi::subject_episode_titles(subject_id, 500).await {
        for t in titles {
            let title = if !t.name_cn.is_empty() { &t.name_cn } else { &t.name };
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

/// Bind an anime to a chosen Bangumi subject (manual correction).
pub fn bind_anime(anime_id: i64, bangumi_id: i64) -> Result<(), String> {
    let subject = RT
        .block_on(async { bangumi::subject(bangumi_id).await })
        .map_err(|e| e.to_string())?;
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
        "high",
        true,
    )
    .map_err(|e| e.to_string())?;
    // The user's collection status for the newly bound subject.
    if bangumi::has_token() {
        if let Ok(c) = RT.block_on(async { bangumi::collection_status(bangumi_id).await }) {
            let _ = db::set_collection(anime_id, c.unwrap_or(0));
        }
    }
    // Manual re-match can point this entry at a subject another entry already
    // has — fold them together like the auto-matcher does.
    let _ = db::merge_duplicate_bindings();
    Ok(())
}
