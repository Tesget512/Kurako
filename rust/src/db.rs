use crate::models::{Anime, Episode, LibraryFolder};
use anyhow::Result;
use once_cell::sync::OnceCell;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Mutex;

static DB: OnceCell<Mutex<Connection>> = OnceCell::new();

pub fn init(db_path: &str) -> Result<()> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS library_folders (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            path        TEXT NOT NULL UNIQUE,
            added_at    INTEGER NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'local'
        );
        CREATE TABLE IF NOT EXISTS anime (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            group_key        TEXT NOT NULL UNIQUE,
            title_raw        TEXT NOT NULL,
            bangumi_id       INTEGER,
            name             TEXT,
            name_cn          TEXT,
            summary          TEXT,
            cover_url        TEXT,
            air_date         TEXT,
            total_eps        INTEGER,
            rating           REAL,
            rating_total     INTEGER,
            rating_rank      INTEGER,
            rating_counts    TEXT,
            air_weekday      INTEGER,
            tags             TEXT,
            collection       INTEGER NOT NULL DEFAULT 0,
            match_confidence TEXT NOT NULL DEFAULT 'none',
            corrected        INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS episodes (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            anime_id         INTEGER NOT NULL,
            file_path        TEXT NOT NULL UNIQUE,
            file_name        TEXT NOT NULL,
            episode_no       INTEGER,
            title            TEXT,
            resolution       TEXT,
            release_group    TEXT,
            source_type      TEXT NOT NULL DEFAULT 'local',
            watched          INTEGER NOT NULL DEFAULT 0,
            last_position_ms INTEGER NOT NULL DEFAULT 0,
            duration_ms      INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(anime_id) REFERENCES anime(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS blacklist (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            kind       TEXT NOT NULL,
            value      TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS downloads (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            smb_uri       TEXT NOT NULL UNIQUE,
            local_path    TEXT NOT NULL,
            bytes_total   INTEGER NOT NULL DEFAULT 0,
            created_at    INTEGER NOT NULL,
            anime_id      INTEGER,
            bangumi_id    INTEGER,
            anime_title   TEXT,
            cover_url     TEXT,
            episode_no    INTEGER,
            episode_title TEXT,
            file_name     TEXT
        );
        "#,
    )?;
    // Migrate databases created before these columns existed; the error on an
    // already-present column is expected and ignored.
    for ddl in [
        "ALTER TABLE anime ADD COLUMN rating REAL",
        "ALTER TABLE anime ADD COLUMN rating_total INTEGER",
        "ALTER TABLE anime ADD COLUMN rating_rank INTEGER",
        "ALTER TABLE anime ADD COLUMN rating_counts TEXT",
        "ALTER TABLE anime ADD COLUMN air_weekday INTEGER",
        "ALTER TABLE anime ADD COLUMN tags TEXT",
        "ALTER TABLE anime ADD COLUMN collection INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE library_folders ADD COLUMN last_scanned INTEGER",
        "ALTER TABLE library_folders ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local'",
        "ALTER TABLE episodes ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local'",
        "ALTER TABLE downloads ADD COLUMN anime_id INTEGER",
        "ALTER TABLE downloads ADD COLUMN bangumi_id INTEGER",
        "ALTER TABLE downloads ADD COLUMN anime_title TEXT",
        "ALTER TABLE downloads ADD COLUMN cover_url TEXT",
        "ALTER TABLE downloads ADD COLUMN episode_no INTEGER",
        "ALTER TABLE downloads ADD COLUMN episode_title TEXT",
        "ALTER TABLE downloads ADD COLUMN file_name TEXT",
    ] {
        let _ = conn.execute(ddl, []);
    }
    let _ = DB.set(Mutex::new(conn));
    Ok(())
}

fn with_conn<T>(f: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
    let m = DB
        .get()
        .ok_or_else(|| anyhow::anyhow!("db not initialized"))?;
    let conn = m.lock().unwrap();
    f(&conn)
}

pub fn add_folder(path: &str, now: i64, source_type: &str) -> Result<i64> {
    with_conn(|c| {
        c.execute(
            "INSERT OR IGNORE INTO library_folders(path, added_at, source_type) VALUES (?1, ?2, ?3)",
            params![path, now, source_type],
        )?;
        let id: i64 = c.query_row(
            "SELECT id FROM library_folders WHERE path = ?1",
            params![path],
            |r| r.get(0),
        )?;
        Ok(id)
    })
}

pub fn remove_folder(id: i64) -> Result<()> {
    with_conn(|c| {
        c.execute("DELETE FROM library_folders WHERE id = ?1", params![id])?;
        Ok(())
    })
}

pub fn list_folders() -> Result<Vec<LibraryFolder>> {
    with_conn(|c| {
        let mut stmt = c.prepare(
            "SELECT id, path, added_at, last_scanned, source_type FROM library_folders ORDER BY added_at DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(LibraryFolder {
                    id: r.get(0)?,
                    path: r.get(1)?,
                    added_at: r.get(2)?,
                    last_scanned: r.get(3)?,
                    source_type: r
                        .get::<_, Option<String>>(4)?
                        .unwrap_or_else(|| "local".to_string()),
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// Record the time a folder was last scanned (Unix seconds), for incremental
/// scans that skip unchanged folders.
pub fn set_folder_scanned(id: i64, when: i64) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE library_folders SET last_scanned = ?2 WHERE id = ?1",
            params![id, when],
        )?;
        Ok(())
    })
}

/// Upsert an anime by its group key, returning its id. Preserves existing
/// Bangumi binding unless this is a fresh row.
pub fn upsert_anime(group_key: &str, title_raw: &str) -> Result<i64> {
    with_conn(|c| {
        c.execute(
            "INSERT OR IGNORE INTO anime(group_key, title_raw) VALUES (?1, ?2)",
            params![group_key, title_raw],
        )?;
        let id: i64 = c.query_row(
            "SELECT id FROM anime WHERE group_key = ?1",
            params![group_key],
            |r| r.get(0),
        )?;
        Ok(id)
    })
}

pub fn upsert_episode(
    anime_id: i64,
    file_path: &str,
    file_name: &str,
    episode_no: Option<i64>,
    resolution: Option<&str>,
    release_group: Option<&str>,
    source_type: &str,
) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "INSERT INTO episodes(anime_id, file_path, file_name, episode_no, resolution, release_group, source_type)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(file_path) DO UPDATE SET
                anime_id=excluded.anime_id,
                episode_no=excluded.episode_no,
                resolution=excluded.resolution,
                release_group=excluded.release_group,
                source_type=excluded.source_type",
            params![anime_id, file_path, file_name, episode_no, resolution, release_group, source_type],
        )?;
        Ok(())
    })
}

fn map_anime(r: &rusqlite::Row) -> rusqlite::Result<Anime> {
    Ok(Anime {
        id: r.get("id")?,
        title_raw: r.get("title_raw")?,
        bangumi_id: r.get("bangumi_id")?,
        name: r.get("name")?,
        name_cn: r.get("name_cn")?,
        summary: r.get("summary")?,
        cover_url: r.get("cover_url")?,
        air_date: r.get("air_date")?,
        total_eps: r.get("total_eps")?,
        rating: r.get("rating")?,
        rating_total: r.get("rating_total")?,
        rating_rank: r.get("rating_rank")?,
        rating_counts: r.get("rating_counts")?,
        air_weekday: r.get("air_weekday")?,
        tags: r.get("tags")?,
        collection: r.get::<_, Option<i64>>("collection")?.unwrap_or(0),
        match_confidence: r.get("match_confidence")?,
        corrected: r.get::<_, i64>("corrected")? != 0,
        episode_count: r.get("episode_count")?,
        watched_count: r.get("watched_count")?,
        special_count: r.get("special_count")?,
    })
}

// Distinct numbered episodes so two fansub sources of the same episode count
// once; unnumbered files (menus, NCs, specials) counted separately.
const ANIME_SELECT: &str = r#"
    SELECT a.*,
        (SELECT COUNT(DISTINCT e.episode_no) FROM episodes e
            WHERE e.anime_id = a.id AND e.episode_no IS NOT NULL) AS episode_count,
        (SELECT COUNT(DISTINCT e.episode_no) FROM episodes e
            WHERE e.anime_id = a.id AND e.episode_no IS NOT NULL AND e.watched = 1) AS watched_count,
        (SELECT COUNT(*) FROM episodes e
            WHERE e.anime_id = a.id AND e.episode_no IS NULL) AS special_count
    FROM anime a
"#;

pub fn list_anime() -> Result<Vec<Anime>> {
    with_conn(|c| {
        let sql = format!(
            "{ANIME_SELECT} ORDER BY (a.group_key = '__misc__'), COALESCE(a.name_cn, a.name, a.title_raw)"
        );
        let mut stmt = c.prepare(&sql)?;
        let rows = stmt
            .query_map([], map_anime)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

pub fn get_anime(id: i64) -> Result<Option<Anime>> {
    with_conn(|c| {
        let sql = format!("{ANIME_SELECT} WHERE a.id = ?1");
        let row = c.query_row(&sql, params![id], map_anime).optional()?;
        Ok(row)
    })
}

pub fn list_episodes(anime_id: i64) -> Result<Vec<Episode>> {
    with_conn(|c| {
        let mut stmt = c.prepare(
            "SELECT id, anime_id, file_path, file_name, episode_no, title, resolution,
                    release_group, watched, last_position_ms, duration_ms, source_type
             FROM episodes WHERE anime_id = ?1
             ORDER BY episode_no IS NULL, episode_no, file_name",
        )?;
        let rows = stmt
            .query_map(params![anime_id], |r| {
                Ok(Episode {
                    id: r.get(0)?,
                    anime_id: r.get(1)?,
                    file_path: r.get(2)?,
                    file_name: r.get(3)?,
                    episode_no: r.get(4)?,
                    title: r.get(5)?,
                    resolution: r.get(6)?,
                    release_group: r.get(7)?,
                    watched: r.get::<_, i64>(8)? != 0,
                    last_position_ms: r.get(9)?,
                    duration_ms: r.get(10)?,
                    source_type: r
                        .get::<_, Option<String>>(11)?
                        .unwrap_or_else(|| "local".to_string()),
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub fn bind_bangumi(
    anime_id: i64,
    bangumi_id: i64,
    name: &str,
    name_cn: &str,
    summary: &str,
    cover_url: Option<&str>,
    air_date: Option<&str>,
    total_eps: Option<i64>,
    rating: Option<f64>,
    rating_total: Option<i64>,
    rating_rank: Option<i64>,
    rating_counts: Option<&str>,
    air_weekday: Option<i64>,
    tags: Option<&str>,
    confidence: &str,
    corrected: bool,
) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE anime SET bangumi_id=?2, name=?3, name_cn=?4, summary=?5, cover_url=?6,
                air_date=?7, total_eps=?8, rating=?9, rating_total=?10, rating_rank=?11,
                rating_counts=?12, air_weekday=?13, tags=?14,
                match_confidence=?15, corrected=?16
             WHERE id=?1",
            params![
                anime_id,
                bangumi_id,
                name,
                name_cn,
                summary,
                cover_url,
                air_date,
                total_eps,
                rating,
                rating_total,
                rating_rank,
                rating_counts,
                air_weekday,
                tags,
                confidence,
                corrected as i64
            ],
        )?;
        Ok(())
    })
}

/// Bound anime ids and their subject ids, for collection-status sync.
pub fn bound_anime() -> Result<Vec<(i64, i64)>> {
    with_conn(|c| {
        let mut stmt =
            c.prepare("SELECT id, bangumi_id FROM anime WHERE bangumi_id IS NOT NULL")?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

pub fn set_collection(anime_id: i64, collection: i64) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE anime SET collection=?2 WHERE id=?1",
            params![anime_id, collection],
        )?;
        Ok(())
    })
}

/// Fill in Bangumi episode titles for on-disk episodes that share the same
/// episode_no and are still missing a title.
pub fn set_episode_title(anime_id: i64, ep: i64, title: &str) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE episodes SET title=?3
             WHERE anime_id=?1 AND episode_no=?2 AND (title IS NULL OR title = '')",
            params![anime_id, ep, title],
        )?;
        Ok(())
    })
}

/// Anime rows that still need a Bangumi match (no binding yet).
pub fn unmatched_anime() -> Result<Vec<(i64, String)>> {
    with_conn(|c| {
        // Skip the "__misc__" catch-all bucket — it must never be auto-matched.
        let mut stmt = c.prepare(
            "SELECT id, title_raw FROM anime WHERE bangumi_id IS NULL AND group_key <> '__misc__'",
        )?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// Merge anime rows bound to the SAME Bangumi subject (multiple sources /
/// fansub groups of one show parsed to slightly different titles). Episodes
/// move to the surviving row (the one with the most episodes, lowest id on
/// ties); the duplicates are deleted. Episodes keep their release_group so the
/// UI can still show which source each file came from.
pub fn merge_duplicate_bindings() -> Result<()> {
    with_conn(|c| {
        let mut stmt = c.prepare(
            "SELECT a.bangumi_id, a.id FROM anime a
             WHERE a.bangumi_id IS NOT NULL
             ORDER BY a.bangumi_id,
                      (SELECT COUNT(*) FROM episodes e WHERE e.anime_id = a.id) DESC,
                      a.id",
        )?;
        let rows: Vec<(i64, i64)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut keeper: Option<(i64, i64)> = None; // (bangumi_id, anime_id)
        for (bid, aid) in rows {
            match keeper {
                Some((kb, ka)) if kb == bid => {
                    c.execute(
                        "UPDATE OR IGNORE episodes SET anime_id=?1 WHERE anime_id=?2",
                        params![ka, aid],
                    )?;
                    // A file that somehow exists under both rows would violate
                    // the UNIQUE(file_path); drop the leftover duplicate rows.
                    c.execute("DELETE FROM episodes WHERE anime_id=?1", params![aid])?;
                    c.execute("DELETE FROM anime WHERE id=?1", params![aid])?;
                }
                _ => keeper = Some((bid, aid)),
            }
        }
        Ok(())
    })
}

/// The id of the anime currently bound to `bangumi_id`, if any. After a
/// merge/bind this is "the entry that survived" — the detail page navigates
/// there so a re-match never strands the user on a deleted (now-null) entry.
pub fn anime_id_for_bangumi(bangumi_id: i64) -> Result<Option<i64>> {
    with_conn(|c| {
        let id = c
            .query_row(
                "SELECT id FROM anime WHERE bangumi_id = ?1 ORDER BY id LIMIT 1",
                params![bangumi_id],
                |r| r.get::<_, i64>(0),
            )
            .optional()?;
        Ok(id)
    })
}

/// The file_path of a single episode, used to key its manual-match override.
pub fn episode_file_path(episode_id: i64) -> Result<Option<String>> {
    with_conn(|c| {
        let p = c
            .query_row(
                "SELECT file_path FROM episodes WHERE id = ?1",
                params![episode_id],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(p)
    })
}

/// Whether a file with this path is currently in the library.
pub fn episode_exists(file_path: &str) -> Result<bool> {
    with_conn(|c| {
        let n: i64 = c.query_row(
            "SELECT COUNT(*) FROM episodes WHERE file_path=?1",
            params![file_path],
            |r| r.get(0),
        )?;
        Ok(n > 0)
    })
}

/// Move one episode (by id) under `anime_id`. Used by the per-file manual match
/// to split a file out of its mis-grouped anime.
pub fn move_episode_to_anime(episode_id: i64, anime_id: i64) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE episodes SET anime_id=?2 WHERE id=?1",
            params![episode_id, anime_id],
        )?;
        Ok(())
    })
}

/// Move an episode (by file_path) under `anime_id`, if that file currently
/// exists. Returns whether a row was actually moved. Used to re-apply
/// manual-match overrides after a scan re-inserts the file.
pub fn move_episode_by_path(file_path: &str, anime_id: i64) -> Result<bool> {
    with_conn(|c| {
        let n = c.execute(
            "UPDATE episodes SET anime_id=?2 WHERE file_path=?1",
            params![file_path, anime_id],
        )?;
        Ok(n > 0)
    })
}

/// Distinct parent folders of every episode of `source_type` currently in the
/// library — where its `.kurako-match.json` sidecar would live. Derived by
/// stripping the last path segment (either separator) off each file_path. Used
/// at the scan tail to know which folders to check for sidecars.
pub fn episode_parents(source_type: &str) -> Result<Vec<String>> {
    with_conn(|c| {
        let mut stmt =
            c.prepare("SELECT DISTINCT file_path FROM episodes WHERE source_type = ?1")?;
        let paths: Vec<String> = stmt
            .query_map(params![source_type], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut parents: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for p in paths {
            if let Some(idx) = p.rfind(['/', '\\']) {
                parents.insert(p[..idx].to_string());
            }
        }
        Ok(parents.into_iter().collect())
    })
}

pub fn update_progress(episode_id: i64, position_ms: i64, duration_ms: i64) -> Result<()> {
    with_conn(|c| {
        // mark watched when past 90% of the runtime
        let watched = duration_ms > 0 && position_ms * 100 >= duration_ms * 90;
        c.execute(
            "UPDATE episodes SET last_position_ms=?2, duration_ms=?3, watched = watched OR ?4 WHERE id=?1",
            params![episode_id, position_ms, duration_ms, watched as i64],
        )?;
        Ok(())
    })
}

pub fn set_watched(episode_id: i64, watched: bool) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE episodes SET watched=?2 WHERE id=?1",
            params![episode_id, watched as i64],
        )?;
        Ok(())
    })
}

/// Prune episodes that vanished from disk/share within a scanned scope.
///
/// Deletes every episode of `source_type` whose `file_path` starts with one of
/// `prefixes` (the folders actually walked this scan) but is NOT in `kept` (the
/// files found this scan). This is what makes an incremental scan delete files
/// removed from a folder — for local, SMB and SAF alike, since each locator is
/// a plain string prefix (`D:\anime\…`, `smb://addr/share/sub/…`,
/// `content://…/tree/…/document/…`). Prefix-scoping means an incremental scan
/// that skipped a folder never prunes that folder's still-present episodes.
/// Returns the number of episodes deleted.
pub fn prune_missing(
    source_type: &str,
    prefixes: &[String],
    kept: &std::collections::HashSet<String>,
) -> Result<usize> {
    if prefixes.is_empty() {
        return Ok(0);
    }
    with_conn(|c| {
        let mut stmt = c.prepare("SELECT file_path FROM episodes WHERE source_type = ?1")?;
        let paths: Vec<String> = stmt
            .query_map(params![source_type], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(stmt);
        let mut deleted = 0usize;
        for path in paths {
            let in_scope = prefixes.iter().any(|pre| path.starts_with(pre.as_str()));
            if in_scope && !kept.contains(&path) {
                c.execute("DELETE FROM episodes WHERE file_path = ?1", params![path])?;
                deleted += 1;
            }
        }
        Ok(deleted)
    })
}

/// Delete anime rows left with no episodes (e.g. after [prune_missing] removed
/// their last file). Returns the number of anime deleted.
pub fn delete_empty_anime() -> Result<usize> {
    with_conn(|c| {
        let n = c.execute(
            "DELETE FROM anime WHERE id NOT IN (SELECT DISTINCT anime_id FROM episodes)",
            [],
        )?;
        Ok(n)
    })
}

/// Remove an anime and its episodes (used when a folder is dropped and rescanned).
pub fn clear_all() -> Result<()> {
    with_conn(|c| {
        // Also reset last_scanned so a clear + rescan reprocesses every folder
        // even in incremental mode.
        c.execute_batch(
            "DELETE FROM episodes; DELETE FROM anime; UPDATE library_folders SET last_scanned = NULL;",
        )?;
        Ok(())
    })
}

// ---- Blacklist (user-blocked anime titles / video file paths) ----

use crate::models::BlacklistEntry;

/// Block an item and immediately remove any matching rows from the library.
/// kind "anime": value = anime.title_raw (episodes cascade via anime delete).
/// kind "file":  value = episodes.file_path (anime left in place; it just
/// loses that file — a later rescan won't bring it back).
pub fn add_blacklist(kind: &str, value: &str, now: i64) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "INSERT OR IGNORE INTO blacklist(kind, value, created_at) VALUES (?1, ?2, ?3)",
            params![kind, value, now],
        )?;
        match kind {
            "anime" => {
                // No ON DELETE CASCADE enforcement without PRAGMA foreign_keys;
                // delete episodes explicitly first.
                c.execute(
                    "DELETE FROM episodes WHERE anime_id IN (SELECT id FROM anime WHERE title_raw = ?1)",
                    params![value],
                )?;
                c.execute("DELETE FROM anime WHERE title_raw = ?1", params![value])?;
            }
            "file" => {
                c.execute("DELETE FROM episodes WHERE file_path = ?1", params![value])?;
            }
            _ => anyhow::bail!("unknown blacklist kind: {kind}"),
        }
        Ok(())
    })
}

pub fn list_blacklist() -> Result<Vec<BlacklistEntry>> {
    with_conn(|c| {
        let mut stmt = c.prepare(
            "SELECT id, kind, value, created_at FROM blacklist ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(BlacklistEntry {
                    id: r.get(0)?,
                    kind: r.get(1)?,
                    value: r.get(2)?,
                    created_at: r.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

pub fn remove_blacklist(id: i64) -> Result<()> {
    with_conn(|c| {
        c.execute("DELETE FROM blacklist WHERE id = ?1", params![id])?;
        Ok(())
    })
}

/// Blocked values by kind, for the scanner's filter pass.
pub fn blacklist_values(kind: &str) -> Result<std::collections::HashSet<String>> {
    with_conn(|c| {
        let mut stmt = c.prepare("SELECT value FROM blacklist WHERE kind = ?1")?;
        let rows = stmt
            .query_map(params![kind], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<std::collections::HashSet<_>, _>>()?;
        Ok(rows)
    })
}

// ---- SMB downloads ----

/// Record a completed download (replaces any earlier record for the same URI).
pub fn add_download(smb_uri: &str, local_path: &str, bytes_total: i64, now: i64) -> Result<()> {
    with_conn(|c| add_download_on(c, smb_uri, local_path, bytes_total, now))
}

type DownloadSnapshot = (
    Option<i64>,
    Option<i64>,
    Option<String>,
    Option<String>,
    Option<i64>,
    Option<String>,
    Option<String>,
);

fn add_download_on(
    c: &Connection,
    smb_uri: &str,
    local_path: &str,
    bytes_total: i64,
    now: i64,
) -> Result<()> {
    let snapshot: Option<DownloadSnapshot> = c
        .query_row(
            "SELECT e.anime_id, a.bangumi_id,
                    COALESCE(NULLIF(a.name_cn, ''), NULLIF(a.name, ''), a.title_raw),
                    a.cover_url, e.episode_no, e.title, e.file_name
             FROM episodes e
             JOIN anime a ON a.id = e.anime_id
             WHERE e.file_path = ?1",
            params![smb_uri],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            },
        )
        .optional()?;
    let (anime_id, bangumi_id, anime_title, cover_url, episode_no, episode_title, file_name) =
        snapshot.unwrap_or((None, None, None, None, None, None, None));

    // A re-download refreshes file attributes and any currently-known match.
    // If the library was cleared meanwhile, excluded snapshot fields are NULL;
    // preserve the previous snapshot instead of turning the download unmatched.
    c.execute(
        "INSERT INTO downloads(
             smb_uri, local_path, bytes_total, created_at, anime_id, bangumi_id,
             anime_title, cover_url, episode_no, episode_title, file_name
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(smb_uri) DO UPDATE SET
             local_path = excluded.local_path,
             bytes_total = excluded.bytes_total,
             created_at = excluded.created_at,
             anime_id = COALESCE(excluded.anime_id, downloads.anime_id),
             bangumi_id = COALESCE(excluded.bangumi_id, downloads.bangumi_id),
             anime_title = COALESCE(excluded.anime_title, downloads.anime_title),
             cover_url = COALESCE(excluded.cover_url, downloads.cover_url),
             episode_no = COALESCE(excluded.episode_no, downloads.episode_no),
             episode_title = COALESCE(excluded.episode_title, downloads.episode_title),
             file_name = COALESCE(excluded.file_name, downloads.file_name)",
        params![
            smb_uri,
            local_path,
            bytes_total,
            now,
            anime_id,
            bangumi_id,
            anime_title,
            cover_url,
            episode_no,
            episode_title,
            file_name,
        ],
    )?;
    Ok(())
}

pub fn list_downloads() -> Result<Vec<crate::models::DownloadEntry>> {
    with_conn(|c| {
        let mut stmt = c.prepare(
            "SELECT id, smb_uri, local_path, bytes_total, created_at FROM downloads ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(crate::models::DownloadEntry {
                    id: r.get(0)?,
                    smb_uri: r.get(1)?,
                    local_path: r.get(2)?,
                    bytes_total: r.get(3)?,
                    created_at: r.get(4)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// Remove a download record, returning its local path so the caller can delete
/// the file too.
pub fn remove_download(id: i64) -> Result<Option<String>> {
    with_conn(|c| {
        let path: Option<String> = c
            .query_row(
                "SELECT local_path FROM downloads WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .optional()?;
        c.execute("DELETE FROM downloads WHERE id = ?1", params![id])?;
        Ok(path)
    })
}

/// Downloads joined with their library episode + anime for the management UI.
/// LEFT JOINs: a download whose episode was removed from the library still
/// shows up with just its raw file info.
pub fn list_downloads_detailed() -> Result<Vec<crate::models::DownloadDetail>> {
    with_conn(|c| {
        refresh_download_snapshots_on(c)?;
        list_downloads_detailed_on(c)
    })
}

/// Populate or refresh metadata for downloads created before snapshot columns
/// existed, or for downloads which were matched only after they completed.
/// [add_download_on] preserves an existing snapshot when its live episode is
/// no longer present, so calling this before every management-page read is
/// idempotent and cannot turn a matched download back into an unmatched one.
fn refresh_download_snapshots_on(c: &Connection) -> Result<()> {
    let downloads = {
        let mut stmt = c.prepare(
            "SELECT smb_uri, local_path, bytes_total, created_at
             FROM downloads",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        rows
    };

    for (smb_uri, local_path, bytes_total, created_at) in downloads {
        add_download_on(c, &smb_uri, &local_path, bytes_total, created_at)?;
    }
    Ok(())
}

fn list_downloads_detailed_on(c: &Connection) -> Result<Vec<crate::models::DownloadDetail>> {
    let mut stmt = c.prepare(
        "SELECT d.id, d.smb_uri, d.local_path, d.bytes_total, d.created_at,
                    COALESCE(e.anime_id, d.anime_id),
                    COALESCE(e.episode_no, d.episode_no),
                    COALESCE(e.file_name, d.file_name),
                    COALESCE(NULLIF(a.name_cn, ''), NULLIF(a.name, ''),
                             a.title_raw, d.anime_title),
                    COALESCE(a.cover_url, d.cover_url)
             FROM downloads d
             LEFT JOIN episodes e ON e.file_path = d.smb_uri
             LEFT JOIN anime a ON a.id = e.anime_id
             ORDER BY COALESCE(NULLIF(a.name_cn, ''), NULLIF(a.name, ''),
                               a.title_raw, d.anime_title),
                      COALESCE(e.episode_no, d.episode_no), d.created_at DESC",
    )?;
    let rows = stmt
        .query_map([], |r| {
            let smb_uri: String = r.get(1)?;
            let file_name: Option<String> = r.get(7)?;
            let file_name = file_name
                .unwrap_or_else(|| smb_uri.rsplit('/').next().unwrap_or(&smb_uri).to_string());
            Ok(crate::models::DownloadDetail {
                id: r.get(0)?,
                smb_uri,
                local_path: r.get(2)?,
                bytes_total: r.get(3)?,
                created_at: r.get(4)?,
                anime_id: r.get(5)?,
                anime_title: r.get(8)?,
                cover_url: r.get(9)?,
                episode_no: r.get(6)?,
                file_name,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// The local copy of an SMB file, if one was downloaded.
pub fn download_local_path(smb_uri: &str) -> Result<Option<String>> {
    with_conn(|c| {
        let path: Option<String> = c
            .query_row(
                "SELECT local_path FROM downloads WHERE smb_uri = ?1",
                params![smb_uri],
                |r| r.get(0),
            )
            .optional()?;
        Ok(path)
    })
}

#[cfg(test)]
mod download_tests {
    use super::*;

    fn connection() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE anime (
                 id INTEGER PRIMARY KEY, title_raw TEXT NOT NULL, bangumi_id INTEGER,
                 name TEXT, name_cn TEXT, cover_url TEXT
             );
             CREATE TABLE episodes (
                 anime_id INTEGER NOT NULL, file_path TEXT NOT NULL UNIQUE,
                 file_name TEXT NOT NULL, episode_no INTEGER, title TEXT
             );
             CREATE TABLE downloads (
                 id INTEGER PRIMARY KEY AUTOINCREMENT, smb_uri TEXT NOT NULL UNIQUE,
                 local_path TEXT NOT NULL, bytes_total INTEGER NOT NULL DEFAULT 0,
                 created_at INTEGER NOT NULL, anime_id INTEGER, bangumi_id INTEGER,
                 anime_title TEXT, cover_url TEXT, episode_no INTEGER,
                 episode_title TEXT, file_name TEXT
             );",
        )
        .unwrap();
        c
    }

    #[test]
    fn download_snapshot_survives_library_clear_and_redownload() {
        let c = connection();
        let uri = "smb://server/Anime/show/episode-02.mkv";
        c.execute(
            "INSERT INTO anime(id, title_raw, bangumi_id, name_cn, cover_url)
             VALUES (7, 'Raw title', 12345, '保留的番剧', 'https://img/cover.jpg')",
            [],
        )
        .unwrap();
        c.execute(
            "INSERT INTO episodes(anime_id, file_path, file_name, episode_no, title)
             VALUES (7, ?1, 'episode-02.mkv', 2, '第二集')",
            params![uri],
        )
        .unwrap();

        add_download_on(&c, uri, "/downloads/episode-02.mkv", 100, 1).unwrap();
        c.execute("DELETE FROM episodes", []).unwrap();
        c.execute("DELETE FROM anime", []).unwrap();

        let detail = list_downloads_detailed_on(&c).unwrap().remove(0);
        assert_eq!(detail.anime_id, Some(7));
        assert_eq!(detail.anime_title.as_deref(), Some("保留的番剧"));
        assert_eq!(detail.cover_url.as_deref(), Some("https://img/cover.jpg"));
        assert_eq!(detail.episode_no, Some(2));
        assert_eq!(detail.file_name, "episode-02.mkv");

        add_download_on(&c, uri, "/downloads/new-episode-02.mkv", 200, 2).unwrap();
        let snapshot: (Option<i64>, Option<i64>, Option<String>) = c
            .query_row(
                "SELECT anime_id, bangumi_id, anime_title FROM downloads WHERE smb_uri=?1",
                params![uri],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(snapshot, (Some(7), Some(12345), Some("保留的番剧".into())));
    }

    #[test]
    fn legacy_download_is_backfilled_before_library_clear() {
        let c = connection();
        let uri = "smb://server/Anime/show/episode-03.mkv";
        c.execute(
            "INSERT INTO anime(id, title_raw, bangumi_id, name_cn, cover_url)
             VALUES (8, 'Raw title', 67890, '旧下载番剧', 'https://img/legacy.jpg')",
            [],
        )
        .unwrap();
        c.execute(
            "INSERT INTO episodes(anime_id, file_path, file_name, episode_no, title)
             VALUES (8, ?1, 'episode-03.mkv', 3, '第三集')",
            params![uri],
        )
        .unwrap();
        c.execute(
            "INSERT INTO downloads(smb_uri, local_path, bytes_total, created_at)
             VALUES (?1, '/downloads/episode-03.mkv', 300, 3)",
            params![uri],
        )
        .unwrap();

        refresh_download_snapshots_on(&c).unwrap();
        c.execute("DELETE FROM episodes", []).unwrap();
        c.execute("DELETE FROM anime", []).unwrap();

        let detail = list_downloads_detailed_on(&c).unwrap().remove(0);
        assert_eq!(detail.anime_id, Some(8));
        assert_eq!(detail.anime_title.as_deref(), Some("旧下载番剧"));
        assert_eq!(detail.cover_url.as_deref(), Some("https://img/legacy.jpg"));
        assert_eq!(detail.episode_no, Some(3));
        assert_eq!(detail.file_name, "episode-03.mkv");
    }
}
