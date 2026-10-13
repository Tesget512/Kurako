use crate::recognize::{group_key, is_video_file, parse_filename, parse_stem, ParsedName};
use std::collections::BTreeMap;
use std::path::Path;
use walkdir::WalkDir;

/// Title and key for the catch-all bucket holding files we can't confidently
/// recognise (specials, menus, unnamed clips…). Shown last, never auto-matched.
const MISC_TITLE: &str = "未分类";
const MISC_KEY: &str = "__misc__";

/// A rough measure of how "title-like" a string is: count of alphanumeric and
/// CJK characters. Used to decide whether a filename title is strong enough to
/// override the folder name.
fn title_strength(s: &str) -> usize {
    s.chars()
        .filter(|c| {
            c.is_alphanumeric() && !c.is_ascii_digit() // digits alone (episode/res) don't count
        })
        .count()
}

pub struct FoundFile {
    pub path: String,
    pub file_name: String,
    pub file_size: i64,
    pub parsed: ParsedName,
}

/// A group of episode files that belong to the same anime.
pub struct AnimeGroup {
    pub group_key: String,
    pub title: String,
    pub files: Vec<FoundFile>,
}

/// One video file discovered by a scan, decoupled from HOW it was found. On
/// desktop `uri` is an absolute path and `relative_parent` is the sub-path from
/// the library root to the file's folder; on Android (SAF) `uri` is a
/// `content://` document URI and `relative_parent` is the folder tree Dart
/// walked. Empty `relative_parent` means the file sits at the library root.
pub struct ScannedFile {
    pub uri: String,
    pub file_name: String,
    pub file_size: i64,
    pub relative_parent: String,
}

/// Recursively collect every video file under `root`.
pub fn scan_folder(root: &str) -> anyhow::Result<Vec<(String, String, String, i64)>> {
    // returns (full_path, file_name, parent_dir, file_size)
    let mut out = Vec::new();
    for entry in WalkDir::new(root).follow_links(false).into_iter() {
        let entry = entry?;
        if crate::scan_control::is_cancelled() {
            anyhow::bail!("扫描已取消");
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let file_name = entry.file_name().to_string_lossy().to_string();
        if !is_video_file(&file_name) {
            continue;
        }
        let parent = entry
            .path()
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let file_size = entry.metadata()?.len() as i64;
        out.push((
            entry.path().to_string_lossy().to_string(),
            file_name,
            parent,
            file_size,
        ));
    }
    Ok(out)
}

/// Whether a directory name looks like a season/quality sub-bucket rather than
/// a distinct show (so we climb to the parent for the title).
fn is_generic_dir(name: &str) -> bool {
    let n = name.trim().to_lowercase();
    if n.is_empty() {
        return true;
    }
    let generic = [
        "specials",
        "special",
        "extras",
        "extra",
        "sp",
        "sps",
        "cd",
        "cds",
        "scan",
        "scans",
        "ova",
        "ovas",
        "oad",
        "oav",
        "menu",
        "menus",
        "movie",
        "movies",
        "bonus",
        "nc",
        "ncop",
        "nced",
        "pv",
        "cm",
        "bd",
        "bdrip",
        "bdmv",
        "disc",
        "vol",
        "特典",
        "特典映像",
        "映像特典",
        "映像",
        "花絮",
        "菜单",
        "预告",
        "宣传",
        "无字幕",
        "字幕",
        "音乐",
        "ost",
        "sound",
        "soundtrack",
        "cds&scans",
        "cd&scan",
        "extra&scan",
    ];
    if generic.contains(&n.as_str()) {
        return true;
    }
    if n.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    // Chinese "第N卷", "Disc N", "Vol.N", "特典xxx", "全集xxx" etc.
    if n.contains("特典") || n.contains("映像特典") || n.contains("scans") || n.contains("menu")
    {
        return true;
    }
    let re_season = regex::Regex::new(r"^(s|season)\s*\d{1,2}$").unwrap();
    let re_cn_season = regex::Regex::new(r"^第[一二三四五六七八九十\d]+[季卷部]$").unwrap();
    let re_disc = regex::Regex::new(r"(?i)^(disc|disk|vol|volume|cd)\s*\.?\s*\d{1,2}$").unwrap();
    let re_res =
        regex::Regex::new(r"(?i)^\d{3,4}[pi]$|^(bd|bdrip|bdbox|bluray|web|webrip)$").unwrap();
    re_season.is_match(&n)
        || re_cn_season.is_match(&n)
        || re_disc.is_match(&n)
        || re_res.is_match(&n)
}

/// Derive an anime title for a folder given its path relative to the library
/// root ("" = root). Climbs past generic sub-buckets (特典/SP/Season N…) toward
/// the root, returning the first usable title.
fn folder_title(dir: &str) -> Option<ParsedName> {
    let mut cur = Path::new(dir);
    for _ in 0..4 {
        let name = cur.file_name()?.to_string_lossy().to_string();

        // A folder like "World Dai Star 特典" / "Show SP" / "Show Specials" is a
        // sibling specials bucket: strip the generic marker and use the base
        // title so the extras fold into the main show.
        if let Some(base) = strip_special_suffix(&name) {
            let parsed = parse_stem(&base);
            if crate::recognize::group_key(&parsed.title).len() >= 2 {
                return Some(parsed);
            }
        }

        if !is_generic_dir(&name) {
            let parsed = parse_stem(&name);
            if crate::recognize::group_key(&parsed.title).len() >= 2 {
                return Some(parsed);
            }
        }
        cur = cur.parent()?;
    }
    None
}

/// If `name` is "<title> <special-marker>" (e.g. "World Dai Star 特典",
/// "Show SP", "Show Specials", "Show BD特典"), return just "<title>". Returns
/// None when the name is either purely generic or has no special marker.
fn strip_special_suffix(name: &str) -> Option<String> {
    let re = regex::Regex::new(
        r"(?i)^(.*?)[\s_\-]+(特典|特典映像|映像特典|specials?|extras?|sp|sps|ova|oad|nc(op|ed)?|menu|scans?|花絮|bonus|bd特典)\s*$",
    )
    .unwrap();
    let caps = re.captures(name.trim())?;
    let base = caps.get(1)?.as_str().trim();
    if base.chars().filter(|c| c.is_alphanumeric()).count() >= 2 {
        Some(base.to_string())
    } else {
        None
    }
}

/// Group all video files under a library folder into anime.
///
/// Strategy: files sharing a parent directory are the same show; the show's
/// title is derived from the (non-generic) folder name. Only when the folder
/// name yields nothing usable do we fall back to per-file parsing.
pub fn group_library(library_root: &str) -> anyhow::Result<Vec<AnimeGroup>> {
    Ok(group_files(enumerate_library(library_root)?))
}

/// Enumerate one local root into the same portable shape used by SAF, SMB and
/// WebDAV. Keeping this separate lets Flutter process every source in one
/// explicit priority order before recognition and matching.
pub fn enumerate_library(library_root: &str) -> anyhow::Result<Vec<ScannedFile>> {
    let files = scan_folder(library_root)?;
    // Convert absolute paths into ScannedFile with a relative parent path, so
    // the grouping logic is shared with the SAF (Android) path.
    let root = Path::new(library_root);
    Ok(files
        .into_iter()
        .map(|(path, name, parent, file_size)| {
            let rel = Path::new(&parent)
                .strip_prefix(root)
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();
            ScannedFile {
                uri: path,
                file_name: name,
                file_size,
                relative_parent: rel,
            }
        })
        .collect())
}

/// Group a list of already-discovered files into anime. Shared by the desktop
/// walkdir path ([group_library]) and the Android SAF path (Dart enumerates the
/// content:// tree). `relative_parent` is the folder path from the library root
/// ("" = root), using "/" separators.
pub fn group_files(files: Vec<ScannedFile>) -> Vec<AnimeGroup> {
    // Bucket files by their (relative) parent directory.
    let mut by_dir: BTreeMap<String, Vec<(String, String, i64)>> = BTreeMap::new();
    for f in files {
        by_dir
            .entry(f.relative_parent)
            .or_default()
            .push((f.uri, f.file_name, f.file_size));
    }

    let mut groups: BTreeMap<String, AnimeGroup> = BTreeMap::new();

    for (dir, entries) in by_dir {
        if crate::scan_control::is_cancelled() {
            break;
        }
        // Root files (empty relative parent) have no folder title.
        let folder_parsed = if dir.is_empty() {
            None
        } else {
            folder_title(&dir)
        };

        for (path, name, file_size) in entries {
            if crate::scan_control::is_cancelled() {
                break;
            }
            let file_parsed = parse_filename(&name);

            // Decide the title. Release groups put the real anime name in the
            // filename (e.g. "[DBD-Raws][Onii-chan wa Oshimai!][...]"), so a
            // strong filename title WINS over the folder — folders are often
            // just buckets like "特典"/"SP"/"Season 1".
            let file_title = file_parsed.title.trim().to_string();
            let file_strong = title_strength(&file_title) >= 3;

            let folder_title_str = folder_parsed
                .as_ref()
                .map(|p| p.title.clone())
                .filter(|t| group_key(t).len() >= 2);

            let title = if file_strong {
                file_title.clone()
            } else if let Some(ft) = folder_title_str.clone() {
                ft
            } else if !file_title.is_empty() {
                file_title.clone()
            } else {
                MISC_TITLE.to_string()
            };

            let key = if title == MISC_TITLE {
                MISC_KEY.to_string()
            } else {
                group_key(&title)
            };
            let (title, key) = if key.is_empty() {
                (MISC_TITLE.to_string(), MISC_KEY.to_string())
            } else {
                (title, key)
            };

            let entry = groups.entry(key.clone()).or_insert_with(|| AnimeGroup {
                group_key: key.clone(),
                title: title.clone(),
                files: Vec::new(),
            });
            entry.files.push(FoundFile {
                path,
                file_name: name,
                file_size,
                parsed: file_parsed,
            });
        }
    }

    groups.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filename_title_beats_generic_folder() {
        // Folder "特典映像" is generic; the filename carries the real title.
        assert!(is_generic_dir("特典映像"));
        assert!(is_generic_dir("SP"));
        assert!(is_generic_dir("Scans"));
        assert!(is_generic_dir("Season 1"));
        assert!(is_generic_dir("第二季"));
        assert!(!is_generic_dir("Onii-chan wa Oshimai!"));
    }

    #[test]
    fn onii_chan_title_extracted() {
        let p = parse_filename(
            "[DBD-Raws][Onii-chan wa Oshimai!][Tokuten][1080P][BDRip][HEVC-10bit][FLAC+AC3].mkv",
        );
        assert!(
            p.title.to_lowercase().contains("onii-chan wa oshimai"),
            "got title: {:?}",
            p.title
        );
    }

    #[test]
    fn title_strength_ignores_digits() {
        assert!(title_strength("01") == 0);
        assert!(title_strength("Frieren") >= 3);
        assert!(title_strength("茜色少女") >= 3);
    }

    #[test]
    fn special_suffix_stripped() {
        assert_eq!(
            strip_special_suffix("World Dai Star 特典").as_deref(),
            Some("World Dai Star")
        );
        assert_eq!(
            strip_special_suffix("Frieren SP").as_deref(),
            Some("Frieren")
        );
        assert_eq!(
            strip_special_suffix("Show Specials").as_deref(),
            Some("Show")
        );
        assert_eq!(
            strip_special_suffix("Show_特典映像").as_deref(),
            Some("Show")
        );
        // No special marker → None (handled by normal folder logic).
        assert_eq!(strip_special_suffix("World Dai Star"), None);
        // Pure generic → None.
        assert_eq!(strip_special_suffix("特典"), None);
    }
}
