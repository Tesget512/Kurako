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
        "#,
    )?;
    // Migrate databases created before these columns existed; the error on an
    // already-present column is expected and ignored.
    for ddl in [
        "ALTER TABLE anime ADD COLUMN rating REAL",
        "ALTER TABLE anime ADD COLUMN air_weekday INTEGER",
        "ALTER TABLE anime ADD COLUMN tags TEXT",
        "ALTER TABLE anime ADD COLUMN collection INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE library_folders ADD COLUMN last_scanned INTEGER",
        "ALTER TABLE library_folders ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local'",
        "ALTER TABLE episodes ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local'",
    ] {
        let _ = conn.execute(ddl, []);
    }
    let _ = DB.set(Mutex::new(conn));
    Ok(())
}

fn with_conn<T>(f: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
    let m = DB.get().ok_or_else(|| anyhow::anyhow!("db not initialized"))?;
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
        let row = c
            .query_row(&sql, params![id], map_anime)
            .optional()?;
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
    air_weekday: Option<i64>,
    tags: Option<&str>,
    confidence: &str,
    corrected: bool,
) -> Result<()> {
    with_conn(|c| {
        c.execute(
            "UPDATE anime SET bangumi_id=?2, name=?3, name_cn=?4, summary=?5, cover_url=?6,
                air_date=?7, total_eps=?8, rating=?9, air_weekday=?10, tags=?11,
                match_confidence=?12, corrected=?13
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
        let mut stmt = c.prepare("SELECT id, bangumi_id FROM anime WHERE bangumi_id IS NOT NULL")?;
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
