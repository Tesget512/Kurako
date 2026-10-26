use crate::watch_history::{self, WatchEntry, WatchSegment, WatchStatistics};

pub fn record_watch_segment(segment: WatchSegment) -> Result<(), String> {
    crate::db::with_conn(|c| watch_history::insert(c, &segment)).map_err(|e| e.to_string())
}

pub fn watch_statistics(
    start_ms: i64,
    end_ms: i64,
    day_boundaries: Vec<i64>,
) -> Result<WatchStatistics, String> {
    crate::db::with_conn(|c| watch_history::statistics(c, start_ms, end_ms, &day_boundaries))
        .map_err(|e| e.to_string())
}

pub fn watch_history(offset: i64, limit: i64) -> Result<Vec<WatchEntry>, String> {
    crate::db::with_conn(|c| watch_history::history(c, offset, limit)).map_err(|e| e.to_string())
}
