use anyhow::{ensure, Result};
use rusqlite::{params, Connection};
use std::collections::HashSet;

#[derive(Clone, Debug)]
pub struct WatchSegment {
    pub id: String,
    pub session_id: String,
    pub media_key: String,
    pub anime_id: i64,
    pub episode_id: i64,
    pub episode_no: Option<i64>,
    pub anime_title: String,
    pub episode_title: String,
    pub file_name: String,
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Clone, Debug)]
pub struct WatchEntry {
    pub session_id: String,
    pub media_key: String,
    pub anime_id: i64,
    pub episode_id: i64,
    pub episode_no: Option<i64>,
    pub anime_title: String,
    pub episode_title: String,
    pub file_name: String,
    pub started_ms: i64,
    pub last_watched_ms: i64,
    pub watched_ms: i64,
    pub available: bool,
}

#[derive(Clone, Debug)]
pub struct WatchDay {
    pub start_ms: i64,
    pub watched_ms: i64,
}

#[derive(Clone, Debug)]
pub struct WatchStatistics {
    pub total_ms: i64,
    pub anime_count: i64,
    pub episode_count: i64,
    pub days: Vec<WatchDay>,
    pub episodes: Vec<WatchEntry>,
}

pub(crate) fn initialize(c: &Connection) -> Result<()> {
    // Snapshots deliberately have no foreign keys: library cleanup must not
    // erase the user's viewing history.
    c.execute_batch(
        "CREATE TABLE IF NOT EXISTS watch_segments (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, media_key TEXT NOT NULL,
        anime_id INTEGER NOT NULL, episode_id INTEGER NOT NULL, episode_no INTEGER,
        anime_title TEXT NOT NULL, episode_title TEXT NOT NULL, file_name TEXT NOT NULL,
        start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL CHECK(end_ms > start_ms)
    );
    CREATE INDEX IF NOT EXISTS watch_segments_time ON watch_segments(end_ms, start_ms);
    CREATE INDEX IF NOT EXISTS watch_segments_session ON watch_segments(session_id, media_key);",
    )?;
    Ok(())
}

pub(crate) fn insert(c: &Connection, s: &WatchSegment) -> Result<()> {
    ensure!(
        s.start_ms >= 0 && s.end_ms > s.start_ms,
        "invalid watch interval"
    );
    ensure!(
        s.end_ms - s.start_ms <= 60_000,
        "watch interval exceeds one minute"
    );
    ensure!(
        !s.id.is_empty() && !s.session_id.is_empty() && !s.media_key.is_empty(),
        "missing watch identity"
    );
    ensure!(
        s.id.len() <= 128 && s.session_id.len() <= 128 && s.media_key.len() <= 256,
        "watch identity too long"
    );
    ensure!(
        s.anime_title.len() <= 16_384
            && s.episode_title.len() <= 16_384
            && s.file_name.len() <= 16_384,
        "watch label too long"
    );
    c.execute(
        "INSERT INTO watch_segments VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
        ON CONFLICT(id) DO NOTHING",
        params![
            s.id,
            s.session_id,
            s.media_key,
            s.anime_id,
            s.episode_id,
            s.episode_no,
            s.anime_title,
            s.episode_title,
            s.file_name,
            s.start_ms,
            s.end_ms
        ],
    )?;
    Ok(())
}

const ENTRY_COLUMNS: &str = "session_id, media_key, anime_id, episode_id, episode_no,
    anime_title, episode_title, file_name, first_watch, last_watch, watched";
const AVAILABLE: &str = "CASE WHEN episode_id > 0 THEN EXISTS(
    SELECT 1 FROM episodes e WHERE e.id=w.episode_id AND e.anime_id=w.anime_id AND e.file_name=w.file_name)
    ELSE EXISTS(SELECT 1 FROM downloads d WHERE d.id=-w.episode_id
        AND (d.file_name=w.file_name OR d.file_name IS NULL)) END";

fn entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<WatchEntry> {
    Ok(WatchEntry {
        session_id: row.get(0)?,
        media_key: row.get(1)?,
        anime_id: row.get(2)?,
        episode_id: row.get(3)?,
        episode_no: row.get(4)?,
        anime_title: row.get(5)?,
        episode_title: row.get(6)?,
        file_name: row.get(7)?,
        started_ms: row.get(8)?,
        last_watched_ms: row.get(9)?,
        watched_ms: row.get(10)?,
        available: row.get(11)?,
    })
}

pub(crate) fn statistics(
    c: &Connection,
    start: i64,
    end: i64,
    boundaries: &[i64],
) -> Result<WatchStatistics> {
    ensure!(start >= 0 && end > start, "invalid statistics range");
    ensure!(
        boundaries.len() <= 367
            && (boundaries.is_empty()
                || (boundaries.len() >= 2
                    && boundaries[0] == start
                    && *boundaries.last().unwrap() == end
                    && boundaries.windows(2).all(|pair| pair[0] < pair[1]))),
        "invalid day boundaries"
    );
    let sql = format!(
        "WITH scoped AS (
        SELECT *, MIN(MAX(start_ms,?1)) OVER same_episode AS first_watch,
        MAX(MIN(end_ms,?2)) OVER same_episode AS last_watch,
        SUM(MIN(end_ms,?2)-MAX(start_ms,?1)) OVER same_episode AS watched,
        ROW_NUMBER() OVER (PARTITION BY media_key ORDER BY end_ms DESC,id DESC) AS latest
        FROM watch_segments WHERE end_ms>?1 AND start_ms<?2
        WINDOW same_episode AS (PARTITION BY media_key)
    ) SELECT {ENTRY_COLUMNS}, {AVAILABLE} FROM scoped w WHERE latest=1
        ORDER BY watched DESC,media_key"
    );
    let mut stmt = c.prepare(&sql)?;
    let episodes = stmt
        .query_map(params![start, end], entry)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut days: Vec<WatchDay> = boundaries
        .windows(2)
        .map(|pair| WatchDay {
            start_ms: pair[0],
            watched_ms: 0,
        })
        .collect();
    if !days.is_empty() {
        let mut stmt = c.prepare(
            "SELECT start_ms,end_ms FROM watch_segments WHERE end_ms>?1 AND start_ms<?2",
        )?;
        for row in stmt.query_map(params![start, end], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
        })? {
            let (a, b) = row?;
            let mut i = boundaries
                .partition_point(|&x| x <= a.max(start))
                .saturating_sub(1);
            while i < days.len() && boundaries[i] < b {
                days[i].watched_ms += b.min(boundaries[i + 1]) - a.max(boundaries[i]);
                i += 1;
            }
        }
    }
    let anime_count = episodes
        .iter()
        .map(|e| {
            if e.anime_id > 0 {
                format!("id:{}", e.anime_id)
            } else {
                format!("title:{}", e.anime_title)
            }
        })
        .collect::<HashSet<_>>()
        .len() as i64;
    Ok(WatchStatistics {
        total_ms: episodes.iter().map(|e| e.watched_ms).sum(),
        anime_count,
        episode_count: episodes.len() as i64,
        days,
        episodes,
    })
}

pub(crate) fn history(c: &Connection, offset: i64, limit: i64) -> Result<Vec<WatchEntry>> {
    ensure!(
        offset >= 0 && (1..=100).contains(&limit),
        "invalid history page"
    );
    let sql = format!(
        "WITH scoped AS (
        SELECT *, MIN(start_ms) OVER same_session AS first_watch,
        MAX(end_ms) OVER same_session AS last_watch,
        SUM(end_ms-start_ms) OVER same_session AS watched,
        ROW_NUMBER() OVER (PARTITION BY session_id,media_key ORDER BY end_ms DESC,id DESC) AS latest
        FROM watch_segments WINDOW same_session AS (PARTITION BY session_id,media_key)
    ) SELECT {ENTRY_COLUMNS}, {AVAILABLE} FROM scoped w WHERE latest=1
        ORDER BY last_watch DESC,session_id DESC,media_key LIMIT ?1 OFFSET ?2"
    );
    let mut stmt = c.prepare(&sql)?;
    let rows = stmt
        .query_map(params![limit, offset], entry)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connection() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE episodes(id INTEGER PRIMARY KEY, anime_id INTEGER, file_name TEXT);
            CREATE TABLE downloads(id INTEGER PRIMARY KEY, file_name TEXT);",
        )
        .unwrap();
        initialize(&c).unwrap();
        initialize(&c).unwrap();
        c
    }

    fn segment(id: &str, start: i64, end: i64) -> WatchSegment {
        WatchSegment {
            id: id.into(),
            session_id: "session-1".into(),
            media_key: "anime:7:ep:1".into(),
            anime_id: 7,
            episode_id: 9,
            episode_no: Some(1),
            anime_title: "Test series".into(),
            episode_title: "First episode".into(),
            file_name: "episode.mkv".into(),
            start_ms: start,
            end_ms: end,
        }
    }

    #[test]
    fn retries_are_idempotent_and_ranges_clip_segments() {
        let c = connection();
        let s = segment("a", 1000, 6000);
        insert(&c, &s).unwrap();
        insert(&c, &s).unwrap();
        insert(&c, &segment("b", 6000, 10000)).unwrap();
        let report = statistics(&c, 2000, 8000, &[2000, 5000, 8000]).unwrap();
        assert_eq!(report.total_ms, 6000);
        assert_eq!((report.anime_count, report.episode_count), (1, 1));
        assert_eq!(
            report.days.iter().map(|d| d.watched_ms).collect::<Vec<_>>(),
            [3000, 3000]
        );
        assert_eq!(report.episodes[0].watched_ms, 6000);
        assert_eq!(statistics(&c, 10000, 11000, &[]).unwrap().total_ms, 0);
    }

    #[test]
    fn history_groups_sessions_and_survives_media_removal() {
        let c = connection();
        c.execute("INSERT INTO episodes VALUES(9,7,'episode.mkv')", [])
            .unwrap();
        insert(&c, &segment("a", 0, 5000)).unwrap();
        insert(&c, &segment("b", 5000, 8000)).unwrap();
        let mut next = segment("c", 10000, 12000);
        next.session_id = "session-2".into();
        insert(&c, &next).unwrap();
        let recent = history(&c, 0, 1).unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].watched_ms, 2000);
        assert!(recent[0].available);
        let older = history(&c, 1, 1).unwrap();
        assert_eq!(older[0].watched_ms, 8000);
        c.execute("DELETE FROM episodes", []).unwrap();
        let retained = history(&c, 0, 20).unwrap();
        assert_eq!(retained.len(), 2);
        assert!(!retained[0].available);
        assert_eq!(retained[0].episode_title, "First episode");
    }

    #[test]
    fn validates_intervals_and_local_day_boundaries() {
        let c = connection();
        assert!(insert(&c, &segment("a", 5000, 4000)).is_err());
        assert!(insert(&c, &segment("a", 0, 0)).is_err());
        assert!(statistics(&c, 0, 20, &[0, 20, 10]).is_err());
        assert!(history(&c, -1, 20).is_err());
        // Local days can be 23 or 25 hours. Boundaries are supplied by Dart.
        insert(&c, &segment("a", 82_798_000, 82_802_000)).unwrap();
        let report = statistics(&c, 0, 172_800_000, &[0, 82_800_000, 172_800_000]).unwrap();
        assert_eq!(
            report.days.iter().map(|d| d.watched_ms).collect::<Vec<_>>(),
            [2000, 2000]
        );
    }

    #[test]
    fn aggregation_uses_latest_snapshot_and_download_identity() {
        let c = connection();
        insert(&c, &segment("a", 0, 4000)).unwrap();
        let mut downloaded = segment("b", 5000, 8000);
        downloaded.episode_id = -42;
        downloaded.episode_title = "Updated episode title".into();
        c.execute("INSERT INTO downloads VALUES(42,'episode.mkv')", [])
            .unwrap();
        insert(&c, &downloaded).unwrap();
        let report = statistics(&c, 1000, 9000, &[]).unwrap();
        assert_eq!(report.total_ms, 6000);
        assert_eq!(report.episodes[0].episode_id, -42);
        assert_eq!(report.episodes[0].episode_title, "Updated episode title");
        assert_eq!(report.episodes[0].started_ms, 1000);
        assert!(report.episodes[0].available);
        assert!(history(&c, 0, 10).unwrap()[0].available);
        // Legacy downloads predate the optional file_name snapshot column.
        c.execute("UPDATE downloads SET file_name=NULL WHERE id=42", [])
            .unwrap();
        assert!(history(&c, 0, 10).unwrap()[0].available);
        c.execute("DELETE FROM downloads WHERE id=42", []).unwrap();
        assert!(!history(&c, 0, 10).unwrap()[0].available);
    }
}
