use anitomy::{parse, ElementKind};
use once_cell::sync::Lazy;
use regex::Regex;
use unicode_normalization::UnicodeNormalization;

/// Result of parsing a filename or folder name, backed by anitomy-rs.
#[derive(Debug, Clone)]
pub struct ParsedName {
    pub title: String,
    pub episode_no: Option<i64>,
    /// The other number of a bracketed `A_B` pair (season-relative `A`) when
    /// `episode_no` took `B`. Lets metadata refresh fall back to `A` if
    /// Bangumi does not know `B`.
    pub episode_alt: Option<i64>,
    pub resolution: Option<String>,
    pub release_group: Option<String>,
}

const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "wmv", "flv", "m4v", "ts", "webm", "rmvb", "mpg", "mpeg",
];

pub fn is_video_file(name: &str) -> bool {
    name.rsplit('.')
        .next()
        .map(|e| VIDEO_EXTS.contains(&e.to_lowercase().as_str()))
        .unwrap_or(false)
}

// Known fansub/encode group name fragments to strip from the FRONT of a title
// when a flattened (all-underscore) filename glued them on. Lowercase, matched
// as whole space-separated words.
static GROUP_WORDS: &[&str] = &[
    "nekomoe",
    "kissaten",
    "vcb",
    "studio",
    "vcb-studio",
    "lilith",
    "raws",
    "lilith-raws",
    "airota",
    "dhr",
    "makarihoshiyume",
    "kissub",
    "kisssub",
    "dbd",
    "dbd-raws",
    "ohys",
    "ohys-raws",
    "sweetsub",
    "moozzi2",
    "philosophy",
    "jibaku",
    "ktkj",
    "sakurato",
    "haruhana",
    "ани",
    "leopard",
    "leopard-raws",
    "orion",
    "beatrice",
    "beatrice-raws",
    "uha",
    "uhawmaki",
    "mabors",
    "mabors-sub",
    "comicat",
    "kamigami",
    "hkg",
    "skytree",
    "bmf",
    "ani",
    "baha",
    "greentea",
    "dynamis",
    "prejudice",
    "newjk",
    "fsd",
    "sub",
];

// Multi-word group phrases, checked before single words so "Dynamis One" strips
// as a unit ("one" alone would be far too dangerous to strip).
static GROUP_PHRASES: &[&str] = &[
    "nekomoe kissaten",
    "vcb studio",
    "lilith raws",
    "dbd raws",
    "ohys raws",
    "leopard raws",
    "beatrice raws",
    "mabors sub",
    "studio greentea",
    "dynamis one",
    "prejudice studio",
    "moozzi2 sp",
];

// Technical tokens (codec/source/audio/sub-lang/container) — stripped anywhere.
static RE_TECH_WORD: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"(?i)^(ma10p|ma|hi10p|hi10|10bit|8bit|yuv420p10|x264|x265|h264|h265|hevc|avc|vc-1|xvid|divx|aac|aacx?\d?|ac3|eac3|flac|flacx?\d?|dts|dtshd|truehd|opus|opusx?\d?|mp3|fla|bdrip|bd|bdbox|bdmv|bluray|blu-ray|web|webrip|web-dl|webdl|dvd|dvdrip|hdtv|remux|big5|gb|gbk|chs|cht|jpsc|jptc|jpn|jp|sc|tc|简|繁|日|简体|繁体|简日|繁日|简繁|中日|内封|外挂|内嵌|字幕|双语|repack|ncop|nced|op|ed|sp|menu|cd|scan|scans|ova|oad|60fps|24fps|assx?\d?|mp4|mkv|avi|mov|ts|webm|rmvb|iso|flv|1080p|720p|480p|2160p|1440p|4k)$",
    )
    .unwrap()
});

// A token like "01Ma10p" — episode digits glued to a tech tag. Splits to (num, rest).
static RE_GLUED_EP: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(\d{1,4})([a-z].*)$").unwrap());
// A token like "clannad01" — a letter title glued directly to a trailing episode
// number with no separator. Group 1 = letters (>=3), group 2 = 1-2 digits, or 3
// digits with a leading zero ("001"). Bare 3-digit like "100" is NOT matched so
// "Mob Psycho 100" survives. Requires >=3 leading letters so short tech-ish
// tokens are left to the other rules.
static RE_GLUED_LETTER_EP: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)^([a-z]{3,})(\d{1,2}|0\d{2})$").unwrap());
static RE_TRAIL_PAREN: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s*\(\d+\)\s*$").unwrap());
static RE_MULTISPACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s{2,}").unwrap());
// Windows copy-duplicate marker: " (1)" / " (2)" right before the extension or
// end of stem. Captured group 1 preserves the extension.
static RE_COPY_MARKER: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\s*\(\d+\)(\.[A-Za-z0-9]+)?$").unwrap());
// Bracketed special-content markers: BD menus, creditless OP/ED, PVs, CMs.
static RE_SPECIAL_MARK: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)\[(menu|ncop|nced|nc|pv|cm|preview)\s*\d*\]").unwrap());
static RE_AMBIGUOUS_EPISODE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)(?:^|[^0-9])(?:ep(?:isode)?\s*)?\d{1,4}\s*(?:[-~～]|\.)\s*\d{1,4}(?:[^0-9]|$)")
        .unwrap()
});
// A bracket holding exactly two short numbers joined by an underscore, as in
// "[01_49]" (season-relative number, then absolute number).
static RE_EPISODE_PAIR: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[(\d{1,4})_(\d{1,4})\]").unwrap());

// Whole-token markers (after trailing digits are removed) for bonus content.
const SPECIAL_TOKENS: &[&str] = &[
    "nc", "ncop", "nced", "op", "ed", "sp", "sps", "ova", "oad", "oav", "pv", "cm", "menu",
    "preview", "trailer", "special", "specials", "extra", "extras", "bonus", "scan", "scans",
];
const SPECIAL_CJK: &[&str] = &[
    "特典", "特別", "特别", "预告", "預告", "花絮", "番外", "片头", "片尾", "菜单", "菜單",
];

/// Whether a file name (or folder segment) names bonus content rather than a
/// main episode: creditless OP/ED, PV, menus, OVA, specials and so on.
pub fn looks_special(name: &str) -> bool {
    let lower = name.to_lowercase();
    if SPECIAL_CJK.iter().any(|m| lower.contains(m)) {
        return true;
    }
    lower
        .split(|c: char| !c.is_alphanumeric())
        .map(|t| t.trim_end_matches(|c: char| c.is_ascii_digit()))
        .any(|t| !t.is_empty() && SPECIAL_TOKENS.contains(&t))
}

const WEAK_SUBTITLE_TITLES: &[&str] = &["ep", "episode", "video", "subtitle", "sub"];

/// Parse a filename (with or without extension) using anitomy.
pub fn parse_filename(file_name: &str) -> ParsedName {
    parse_stem(file_name)
}

/// Whether one subtitle filename belongs to one video filename. Exact stem
/// variants win; a conservative parsed fallback accepts shorter release names
/// only when both the normalized title and explicit episode number agree.
pub fn subtitle_matches_video(video_name: &str, subtitle_name: &str) -> bool {
    let Some((subtitle_stem, subtitle_ext)) = subtitle_name.rsplit_once('.') else {
        return false;
    };
    if !crate::subtitle::is_subtitle_file_name(subtitle_name) {
        return false;
    }

    let video_stem: String = video_name
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(video_name)
        .nfc()
        .collect();
    let subtitle_stem: String = subtitle_stem.nfc().collect();
    let video_lower = video_stem.to_lowercase();
    let subtitle_lower = subtitle_stem.to_lowercase();
    if RE_AMBIGUOUS_EPISODE.is_match(&subtitle_stem)
        && !video_stem.eq_ignore_ascii_case(&subtitle_stem)
    {
        return false;
    }
    if let Some(suffix) = subtitle_lower.strip_prefix(&video_lower) {
        if suffix.is_empty()
            || suffix
                .chars()
                .next()
                .is_some_and(|c| matches!(c, '.' | ' ' | '[' | '(' | '_' | '-'))
        {
            return true;
        }
    }

    // Ranges and decimal episodes are deliberately excluded from fuzzy
    // matching: reducing `01-12` or `01.5` to episode 1 would mis-attach it.
    if RE_AMBIGUOUS_EPISODE.is_match(&video_stem) {
        return false;
    }
    let video = parse_filename(&video_stem);
    let normalized_subtitle_name = format!("{subtitle_stem}.{subtitle_ext}");
    let subtitle = parse_filename(&normalized_subtitle_name);
    let (Some(video_episode), Some(subtitle_episode)) = (video.episode_no, subtitle.episode_no)
    else {
        return false;
    };
    if video_episode != subtitle_episode {
        return false;
    }
    let video_key = group_key(&video.title);
    let subtitle_key = group_key(&subtitle.title);
    video_key == subtitle_key
        && video_key.chars().count() >= 3
        && !video_key.chars().all(|c| c.is_ascii_digit())
        && !WEAK_SUBTITLE_TITLES.contains(&video_key.as_str())
}

/// Parse a stem or full filename using anitomy, mapping its elements onto our
/// simpler `ParsedName`. Anitomy handles release groups, brackets, batch
/// ranges, CJK/romaji titles, and many episode conventions natively.
pub fn parse_stem(input: &str) -> ParsedName {
    // Strip Windows copy-duplicate markers like " (1)" before ".mkv" — anitomy
    // would otherwise read them as episode 1, making every copy look like ep 1.
    let input = RE_COPY_MARKER.replace(input, "$1").to_string();
    let elements = parse(&input);

    let mut title = String::new();
    let mut episode: Option<i64> = None;
    let mut resolution: Option<String> = None;
    let mut release_group: Option<String> = None;
    let mut season: Option<i64> = None;

    for el in &elements {
        match el.kind() {
            ElementKind::Title => {
                if title.is_empty() {
                    title = el.value().trim().to_string();
                }
            }
            ElementKind::Episode => {
                if episode.is_none() {
                    episode = first_number(el.value());
                }
            }
            ElementKind::Season => {
                if season.is_none() {
                    season = first_number(el.value());
                }
            }
            ElementKind::VideoResolution => {
                if resolution.is_none() {
                    resolution = Some(el.value().trim().to_string());
                }
            }
            ElementKind::ReleaseGroup => {
                if release_group.is_none() {
                    release_group = Some(el.value().trim().to_string());
                }
            }
            _ => {}
        }
    }

    // A bare 4-digit "episode" in the plausible-year range is almost always the
    // release year of a movie, not an episode: anitomy only tags the year when
    // it is bracketed or isolated, so "Movie.Title.2026.1080p" falls through to
    // its last-number fallback and would otherwise show as "第 2026 话". No
    // airing show comes near 1900 episodes. An explicit E/EP/第..話 prefix is a
    // keyword path in anitomy too — its value would arrive with that keyword in
    // the element value, so first_number alone cannot distinguish; year-style
    // episode numbers on real shows do not exist yet, so the whole range is
    // treated as a year.
    if episode.is_some_and(|ep| (1900..=2100).contains(&ep)) {
        episode = None;
    }

    // Post-process the title. Flattened all-underscore filenames confuse anitomy
    // (it emits e.g. "Nekomoe kissaten VCB Studio World Dai Star 01Ma10p"), so we
    // strip leading group words, glued episode+tech tokens, and trailing tech.
    let (clean_title, glued_ep, stripped_group) = clean_title(&title);
    let mut clean_title = clean_title;
    // A glued episode ("07" from "07Ma10p") is unambiguous and beats anitomy's
    // guess, which can misfire (e.g. on a leftover copy marker).
    if let Some(g) = glued_ep {
        episode = Some(g);
    }
    // A group prefix stripped from a flattened filename ("Nekomoe kissaten",
    // "Airota", "ANi") is the release source — keep it so the UI can label
    // which fansub/source each file came from.
    if release_group.is_none() {
        release_group = stripped_group;
    }
    // Keep the season in the title so "…S04E10" files group and match
    // separately from other seasons of the same show — dropping it once put
    // season-4 episodes inside the season-3 entry. Season 1 stays bare (base
    // entries on Bangumi usually carry no season marker).
    if let Some(s) = season {
        let low = clean_title.to_lowercase();
        if s >= 2 && !low.contains("season") && !clean_title.contains('季') {
            clean_title = format!("{clean_title} Season {s}");
        }
    }
    // BD menu / NCOP / NCED / PV videos carry bracketed numbers that collide
    // with real episode numbers — treat them as unnumbered specials.
    if RE_SPECIAL_MARK.is_match(&input) {
        episode = None;
    }

    // "[01_49]": anitomy reads no episode from an underscore pair. Take the
    // absolute number (what Bangumi shows) and keep the first as a fallback.
    let mut episode_alt = None;
    if episode.is_none() && !RE_SPECIAL_MARK.is_match(&input) {
        if let Some(c) = RE_EPISODE_PAIR.captures(&input) {
            let a: i64 = c[1].parse().unwrap_or(0);
            let b: i64 = c[2].parse().unwrap_or(0);
            if a >= 1 && b > a && !(1900..=2100).contains(&b) {
                episode = Some(b);
                episode_alt = Some(a);
            }
        }
    }

    ParsedName {
        title: clean_title,
        episode_no: episode,
        episode_alt,
        resolution,
        release_group,
    }
}

/// Clean a raw anitomy title: drop leading known group words, split/strip glued
/// episode+tech tokens ("01Ma10p"), and drop trailing technical tokens. Returns
/// (clean_title, episode_no_found_while_cleaning, stripped_group_prefix).
fn clean_title(raw: &str) -> (String, Option<i64>, Option<String>) {
    let raw = RE_TRAIL_PAREN.replace(raw, "").to_string();
    let mut raw = raw.replace('_', " ");
    let mut group_parts: Vec<String> = Vec::new();

    // Strip leading group words even when glued without a separator to the next
    // token, e.g. "kissatenTHE IDOLM@STER" -> "THE IDOLM@STER". Applied
    // repeatedly so multi-word group names ("Nekomoe kissaten") peel off.
    // Multi-word phrases first, so "Dynamis One" strips as a unit.
    let mut changed = true;
    while changed {
        changed = false;
        let trimmed = raw.trim_start().to_string();
        let low = trimmed.to_lowercase();
        for ph in GROUP_PHRASES {
            if low.starts_with(ph) {
                group_parts.push(trimmed[..ph.len()].to_string());
                raw = trimmed[ph.len()..].to_string();
                changed = true;
                break;
            }
        }
        if changed {
            continue;
        }
        for gw in GROUP_WORDS {
            if low.starts_with(gw) {
                let after = trimmed[gw.len()..].to_string();
                // Strip when followed by a separator/end. A glued
                // uppercase/CJK boundary ("kissatenTHE", "AirotaTHE") only
                // counts for longer words — short ones like "ani"/"sub" would
                // chop real all-caps titles.
                let next = after.chars().next();
                let boundary = match next {
                    None => true,
                    Some(c) if !c.is_alphanumeric() => true,
                    Some(c) => gw.len() >= 5 && !c.is_ascii_lowercase(),
                };
                if boundary {
                    group_parts.push(trimmed[..gw.len()].to_string());
                    raw = after;
                    changed = true;
                    break;
                }
            }
        }
    }

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    let mut kept: Vec<String> = Vec::new();
    let mut found_ep: Option<i64> = None;

    // Skip any remaining leading group words (space-separated form).
    let mut i = 0;
    while i < tokens.len() {
        let low = tokens[i].to_lowercase();
        if GROUP_WORDS.contains(&low.as_str()) {
            group_parts.push(tokens[i].to_string());
            i += 1;
        } else {
            break;
        }
    }

    for tok in &tokens[i..] {
        let low = tok.to_lowercase();
        // Glued episode+tech, e.g. "01Ma10p" -> episode 01, drop the rest.
        if let Some(c) = RE_GLUED_EP.captures(tok) {
            let num: i64 = c[1].parse().unwrap_or(0);
            let rest = &c[2];
            if (1..=1500).contains(&num) && RE_TECH_WORD.is_match(rest) {
                if found_ep.is_none() {
                    found_ep = Some(num);
                }
                continue;
            }
        }
        // Glued letter-title + episode, e.g. "clannad01" -> title "clannad" ep 1.
        // Only when the letters aren't themselves a tech word (so "bdrip01" etc.
        // still falls through to the tech handling below).
        if let Some(c) = RE_GLUED_LETTER_EP.captures(tok) {
            let letters = &c[1];
            let num: i64 = c[2].parse().unwrap_or(0);
            if (1..=1500).contains(&num) && !RE_TECH_WORD.is_match(&letters.to_lowercase()) {
                if found_ep.is_none() {
                    found_ep = Some(num);
                }
                kept.push(letters.to_string());
                continue;
            }
        }
        // Pure technical token — drop.
        if RE_TECH_WORD.is_match(&low) {
            continue;
        }
        // A token that is a resolution glued to more tech, e.g. "1080pJPSC" or
        // "091080p" (episode+resolution) — strip the trailing tech noise.
        let mut cur = match strip_trailing_tech_glue(tok, &mut found_ep) {
            Some(c) => c,
            None => tok.to_string(),
        };
        // Digit-bearing tokens can also glue tech words directly, with no
        // resolution marker: "U14912WebRip", "U149OVA", "U149SPBDRip". Peel
        // known tech suffixes, then treat an over-long trailing digit run as
        // show-number + episode ("U14908" -> "U149" ep 08).
        if cur.chars().any(|c| c.is_ascii_digit()) {
            cur = peel_tech_suffixes(&cur);
            cur = peel_glued_episode(&cur, &mut found_ep);
        }
        if !cur.is_empty() {
            kept.push(cur);
        }
    }

    // If the title still ends in a lone number that looks like an episode
    // (leading-zero form like "09"/"01", or 1-2 digits), pull it out so every
    // episode of the show shares the same title. A 3-digit number without a
    // leading zero (e.g. "100" in "Mob Psycho 100") is kept as part of the title.
    while let Some(last) = kept.last() {
        let is_epishy = last.chars().all(|c| c.is_ascii_digit())
            && ((last.len() <= 2) || (last.len() == 3 && last.starts_with('0')));
        if is_epishy {
            if let Ok(n) = last.parse::<i64>() {
                if found_ep.is_none() && (1..=1500).contains(&n) {
                    found_ep = Some(n);
                }
            }
            kept.pop();
        } else {
            break;
        }
    }

    let mut title = kept.join(" ");
    title = RE_MULTISPACE.replace_all(&title, " ").trim().to_string();
    let group = if group_parts.is_empty() {
        None
    } else {
        Some(group_parts.join(" ").trim().to_string())
    };
    (title, found_ep, group)
}

/// Handle tokens where resolution/episode is glued onto the end with no
/// separator, e.g. "U149091080pJPSC" or "091080p". Returns Some(cleaned) when
/// the token contained a resolution keyword: everything from the resolution on
/// is dropped as noise, and 1-3 trailing digits in the head are taken as the
/// episode number. Returns None when there's no glued resolution.
fn strip_trailing_tech_glue(tok: &str, found_ep: &mut Option<i64>) -> Option<String> {
    let low = tok.to_lowercase();
    // Find the earliest resolution keyword in the token.
    let res_kw = ["2160p", "1440p", "1080p", "720p", "480p", "576p"];
    let pos = res_kw.iter().filter_map(|kw| low.find(kw)).min()?;
    // Head is the byte-prefix before the resolution (ASCII kw so byte pos is safe).
    let mut head = tok[..pos].to_string();

    // Peel 1-3 trailing digits off the head as the episode number.
    let trailing_digits: String = head
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    if !trailing_digits.is_empty() && trailing_digits.len() <= 3 {
        if found_ep.is_none() {
            if let Ok(n) = trailing_digits.parse::<i64>() {
                if (1..=1500).contains(&n) {
                    *found_ep = Some(n);
                }
            }
        }
        let keep = head.len() - trailing_digits.len();
        head.truncate(keep);
    }
    Some(head.trim().to_string())
}

// Tech words that get glued directly onto a digit-bearing title token in fully
// flattened filenames ("U14912WebRip", "U149SPBDRip", "U149OVA"). Ordered
// longest-first so "BDRip" wins over "BD".
const GLUED_TECH_SUFFIXES: &[&str] = &[
    "webrip", "bdrip", "dvdrip", "bluray", "bdbox", "webdl", "hdtv", "remux", "web", "bdmv", "bd",
    "ova", "oad", "ncop", "nced", "sp", "jpsc", "jptc", "big5", "chs", "cht", "gb",
];

/// Repeatedly peel known tech words glued to the END of a token with no
/// separator. Only called for digit-bearing tokens, so plain title words
/// (e.g. a real word ending in "web") are never touched.
fn peel_tech_suffixes(tok: &str) -> String {
    let mut cur = tok.to_string();
    let mut changed = true;
    while changed {
        changed = false;
        let low = cur.to_lowercase();
        for sfx in GLUED_TECH_SUFFIXES {
            if low.len() > sfx.len() && low.ends_with(sfx) {
                cur.truncate(cur.len() - sfx.len());
                changed = true;
                break;
            }
        }
    }
    cur
}

/// If a token ends in an over-long digit run (4+ digits), the last two digits
/// are almost always a glued episode number on top of a numeric show name:
/// "U14908" -> "U149" + ep 08. Shorter runs ("U149", "100") are left alone.
fn peel_glued_episode(tok: &str, found_ep: &mut Option<i64>) -> String {
    let run: usize = tok.chars().rev().take_while(|c| c.is_ascii_digit()).count();
    if run >= 4 && run < tok.chars().count() {
        let cut = tok.len() - 2;
        let (head, ep) = tok.split_at(cut);
        if found_ep.is_none() {
            if let Ok(n) = ep.parse::<i64>() {
                if (1..=99).contains(&n) {
                    *found_ep = Some(n);
                }
            }
        }
        return head.to_string();
    }
    tok.to_string()
}

/// Extract the first integer from a value like "01", "01-12", "1.5".
fn first_number(v: &str) -> Option<i64> {
    let mut digits = String::new();
    for c in v.chars() {
        if c.is_ascii_digit() {
            digits.push(c);
        } else if !digits.is_empty() {
            break;
        }
    }
    digits.parse::<i64>().ok()
}

/// Normalize a title into a grouping key (alphanumeric only, lowercase).
pub fn group_key(title: &str) -> String {
    title
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paired_season_and_absolute_episode_takes_the_absolute_number() {
        // BeanSub tags season-relative and absolute numbers as "[01_49]".
        // anitomy reads no episode from it, which dumped the file into the
        // specials bucket.
        let p =
            parse_filename("[BeanSub][Kusuriya no Hitorigoto S3][01_49][CHS][1080P][x264_AAC].mp4");
        assert_eq!(p.episode_no, Some(49), "{p:?}");
        assert_eq!(p.episode_alt, Some(1), "{p:?}");
        let p =
            parse_filename("[BeanSub][Kusuriya no Hitorigoto S3][01_52][CHS][1080P][x264_AAC].mp4");
        assert_eq!(p.episode_no, Some(52), "{p:?}");
        // Same grouping key as the plain form, so both land in one entry.
        let plain =
            parse_filename("[BeanSub][Kusuriya no Hitorigoto S3][49][CHS][1080P][x264_AAC].mp4");
        assert_eq!(group_key(&p.title), group_key(&plain.title));
        assert_eq!(plain.episode_no, Some(49));
        assert_eq!(plain.episode_alt, None);
    }

    #[test]
    fn bracketed_pairs_that_are_not_episode_pairs_are_left_alone() {
        // Codec/audio tags use underscores too; only a bracket holding two
        // short numbers counts.
        let p = parse_filename("[Grp][Show][1080P][x264_AAC].mkv");
        assert_eq!(p.episode_no, None, "{p:?}");
        // A descending pair is not "season then absolute".
        let p = parse_filename("[Grp][Show][12_01][1080P].mkv");
        assert_eq!(p.episode_no, None, "{p:?}");
        // A pair never overrides an episode anitomy already found.
        let p = parse_filename("[Grp] Show - 07 [01_49][1080P].mkv");
        assert_eq!(p.episode_no, Some(7), "{p:?}");
    }

    #[test]
    fn special_name_detection_covers_bonus_content() {
        for name in [
            "[Grp][Show][NCOP][1080P].mkv",
            "Show NCED 1080p.mkv",
            "Show.PV.1080p.mkv",
            "Show OVA 1080p.mkv",
            "Show 特典映像.mkv",
            "Show Menu.mkv",
        ] {
            assert!(looks_special(name), "{name}");
        }
        for name in [
            "Cosmic.Princess.Kaguya.2026.1080p.NF.WEB-DL.DUAL.DDP5.1.H.264-VARYG.mkv",
            "Cosmic.Princess.Kaguya.2026.1080p.NF.WEB-DL.DUAL.DDP5.1.H.264-VARYG (1).mkv",
            "[Grp] Opening Night Movie [1080p].mkv",
        ] {
            assert!(!looks_special(name), "{name}");
        }
    }

    #[test]
    fn year_in_movie_filename_is_not_episode() {
        // "Cosmic.Princess.Kaguya.2026.1080p..." — anitomy's last-number
        // fallback reads the release year as the episode; it must be dropped
        // so the movie files group as unnumbered specials instead of
        // "第 2026 话".
        let p = parse_filename(
            "Cosmic.Princess.Kaguya.2026.1080p.NF.WEB-DL.DUAL.DDP5.1.H.264-VARYG.mkv",
        );
        assert_eq!(p.episode_no, None, "year leaked as episode: {p:?}");
        assert!(p.title.to_lowercase().contains("kaguya"), "{p:?}");
        assert_eq!(p.resolution.as_deref(), Some("1080p"));
        // The bracketed/isolated year case is a real anitomy Year element; the
        // guard drops it the same way.
        let bracketed = parse_filename("[Group] Movie Title [2026][1080p].mkv");
        assert_eq!(bracketed.episode_no, None, "{bracketed:?}");
    }

    #[test]
    fn four_digit_non_year_episodes_survive() {
        // Long-runners are still far below 1900; a real 4-digit episode keeps
        // its number.
        let p = parse_filename("[Group] Long Show - 1044 [1080p].mkv");
        assert_eq!(p.episode_no, Some(1044), "{p:?}");
        // The scan tests' pre-existing numbers (<=1500) are unaffected.
        let p2 = parse_filename("Show 07 [1080p].mkv");
        assert_eq!(p2.episode_no, Some(7), "{p2:?}");
    }

    #[test]
    fn glued_letter_episode_groups() {
        // "clannad01".."clannad13" plus the folder-style variants must all share
        // one grouping key and expose their episode numbers.
        let key0 = group_key(&parse_filename("clannad01").title);
        for (raw, ep) in [
            ("clannad01", 1),
            ("clannad02", 2),
            ("clannad13", 13),
            ("CLANNAD01", 1),
            ("clannad 01", 1),
            ("[Group] CLANNAD - 01", 1),
        ] {
            let p = parse_filename(raw);
            assert_eq!(
                group_key(&p.title),
                key0,
                "key mismatch for {raw:?} -> {:?}",
                p.title
            );
            assert_eq!(p.episode_no, Some(ep), "ep mismatch for {raw:?}");
        }
        // Bare title with no number stays intact and shares the same key.
        assert_eq!(group_key(&parse_filename("CLANNAD").title), key0);
        assert_eq!(group_key(&parse_stem("clannad").title), key0);
        // A glued 3-digit-without-leading-zero title is NOT split by our rule
        // ("mob100" stays whole, not letters+ep100).
        let mob = parse_filename("mob100");
        assert_eq!(
            mob.episode_no, None,
            "mob100 must not yield ep 100: {:?}",
            mob
        );
        assert_eq!(group_key(&mob.title), "mob100");
    }

    #[test]
    fn season_kept_in_title() {
        let p = parse_filename(
            "[Feibanyama] ReZERO Starting Life in Another World S04E10 [IQIYI WebRip 2160p HEVC AAC Multi-Audio Multi-Subs].mkv",
        );
        assert!(
            p.title.to_lowercase().contains("season 4"),
            "S04 must survive into the title, got: {:?}",
            p.title
        );
        assert_eq!(p.episode_no, Some(10));

        // Season 1 stays bare so it groups with unmarked files of the show.
        let p1 = parse_filename("[Grp] Some Show S01E03 [1080p].mkv");
        assert!(
            !p1.title.to_lowercase().contains("season"),
            "got: {:?}",
            p1.title
        );
        assert_eq!(p1.episode_no, Some(3));
    }

    #[test]
    fn menu_files_are_unnumbered_specials() {
        let p = parse_filename(
            "[DBD-Raws][Re Zero Kara Hajimeru Isekai Seikatsu Shin Henshuu-ban][menu][02][1080P][BDRip][HEVC-10bit][FLAC].mkv",
        );
        assert_eq!(
            p.episode_no, None,
            "menu discs must not claim an episode number"
        );
        // and the real episode 02 keeps its number
        let p2 = parse_filename(
            "[DBD-Raws][Re Zero Kara Hajimeru Isekai Seikatsu Shin Henshuu-ban][02][1080P][BDRip][HEVC-10bit][FLAC].mkv",
        );
        assert_eq!(p2.episode_no, Some(2));
    }

    #[test]
    fn onii_chan_title() {
        let p = parse_filename(
            "[DBD-Raws][Onii-chan wa Oshimai!][01][1080P][BDRip][HEVC-10bit][FLAC].mkv",
        );
        assert!(
            p.title.to_lowercase().contains("onii-chan wa oshimai"),
            "got: {:?}",
            p.title
        );
        assert_eq!(p.episode_no, Some(1));
        assert_eq!(p.release_group.as_deref(), Some("DBD-Raws"));
    }

    #[test]
    fn shinmai_groups_together() {
        // The same show across episodes must produce the same grouping key.
        let a =
            parse_filename("[Lilith-Raws] Shinmai Renkinjutsushi no Tenpo Keiei - 01 [1080p].mkv");
        let b =
            parse_filename("[Lilith-Raws] Shinmai Renkinjutsushi no Tenpo Keiei - 02 [1080p].mkv");
        assert_eq!(group_key(&a.title), group_key(&b.title));
        assert!(!group_key(&a.title).is_empty());
        assert_eq!(a.episode_no, Some(1));
        assert_eq!(b.episode_no, Some(2));
    }

    #[test]
    fn nekomoe_vcb_groups_together() {
        let a = parse_filename(
            "[Nekomoe kissaten&VCB-Studio] World Dai Star [01][Ma10p_1080p][x265_flac].mkv",
        );
        let b = parse_filename(
            "[Nekomoe kissaten&VCB-Studio] World Dai Star [02][Ma10p_1080p][x265_flac].mkv",
        );
        assert_eq!(group_key(&a.title), group_key(&b.title));
        assert!(
            a.title.to_lowercase().contains("world dai star"),
            "got: {:?}",
            a.title
        );
    }

    #[test]
    fn chinese_bracket_title() {
        let p =
            parse_filename("[DHR&MakariHoshiyume][Akanesasu Shoujo][01][BDRip][BIG5][720P].mp4");
        assert!(
            p.title.to_lowercase().contains("akanesasu"),
            "got: {:?}",
            p.title
        );
        assert_eq!(p.episode_no, Some(1));
    }

    #[test]
    fn video_ext() {
        assert!(is_video_file("a.mkv"));
        assert!(!is_video_file("a.txt"));
    }

    #[test]
    fn subtitle_matching_accepts_short_release_name_with_same_title_and_episode() {
        let video = "[DBD-Raws][Happy Sugar Life][01][1080P][BDRip][HEVC-10bit][FLAC].mkv";
        assert!(subtitle_matches_video(video, "Happy Sugar Life 01.ass"));
        assert!(subtitle_matches_video(video, "happy sugar life 01.SRT"));
        assert!(!subtitle_matches_video(video, "Happy Sugar Life 02.ass"));
        assert!(!subtitle_matches_video(video, "Another Show 01.ass"));
    }

    #[test]
    fn subtitle_matching_keeps_strict_stem_boundaries() {
        assert!(subtitle_matches_video(
            "Episode 01.mkv",
            "episode 01.sc.ass"
        ));
        assert!(!subtitle_matches_video("Episode 01.mkv", "Episode 010.ass"));
        assert!(!subtitle_matches_video("Episode 01.mkv", "Episode 01.txt"));
        assert!(!subtitle_matches_video(
            "Happy Sugar Life 01.mkv",
            "Happy Sugar Life 01-12.ass"
        ));
    }

    #[test]
    fn flattened_underscore_filename() {
        // Transcoded/renamed file where "_" replaced all separators, gluing the
        // group name, title, episode and tech tags together.
        let p = parse_filename(
            "Nekomoe_kissaten VCB_Studio_World_Dai_Star_01Ma10p_1080px265_fla (1).mkv",
        );
        assert_eq!(
            group_key(&p.title),
            "worlddaistar",
            "got title: {:?}",
            p.title
        );
        assert_eq!(p.episode_no, Some(1));
    }

    #[test]
    fn flattened_matches_bracketed() {
        // The flattened form must group with the properly-bracketed form.
        let flat =
            parse_filename("Nekomoe_kissaten VCB_Studio_World_Dai_Star_02Ma10p_1080px265_fla.mkv");
        let bracketed = parse_filename(
            "[Nekomoe kissaten&VCB-Studio] World Dai Star [02][Ma10p_1080p][x265_flac].mkv",
        );
        assert_eq!(group_key(&flat.title), group_key(&bracketed.title));
    }

    #[test]
    fn copy_marker_not_episode() {
        // The " (1)" copy markers must NOT all become episode 1; the real
        // episode is glued in "07Ma10p" / "10Ma10p".
        let e7 =
            parse_filename("VCB_Studio_Hina_Logi_From_Luck_&_Logic_07Ma10p_1080px265_flac (1).mkv");
        let e10 = parse_filename(
            "VCB_Studio_Hina_Logi_From_Luck_&_Logic_10Ma10p_1080px265_flac_aac (1).mkv",
        );
        assert_eq!(e7.episode_no, Some(7), "title={:?}", e7.title);
        assert_eq!(e10.episode_no, Some(10), "title={:?}", e10.title);
        // Both are the same show → same group key.
        assert_eq!(group_key(&e7.title), group_key(&e10.title));
        // Title should be about "Luck & Logic", not VCB-Studio.
        assert!(
            e7.title.to_lowercase().contains("luck") || e7.title.to_lowercase().contains("logi"),
            "got title: {:?}",
            e7.title
        );
    }

    #[test]
    fn glued_group_no_separator() {
        // Group name glued directly onto the title with no separator.
        let p =
            parse_filename("Nekomoe_kissatenTHE_IDOLM@STER_CINDERELLA_GIRLS_U149_09_1080pJPSC.mkv");
        let key = group_key(&p.title);
        assert!(
            key.contains("idolm") && key.contains("cinderella"),
            "got title: {:?} key: {:?}",
            p.title,
            key
        );
        assert!(
            !key.starts_with("nekomoe") && !key.starts_with("kissaten"),
            "group name not stripped: {:?}",
            p.title
        );
    }
}
