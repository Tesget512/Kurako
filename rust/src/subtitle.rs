//! Cross-platform external subtitle preparation.
//!
//! libmpv builds do not handle every legacy text encoding consistently. Read a
//! small sidecar once, decode it in Rust, and hand mpv a strict UTF-8 file so
//! subtitle parsing never happens repeatedly on malformed UTF-16 bytes.

use crate::models::PreparedSubtitle;
use anyhow::{Context, Result};
use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use encoding_rs::Encoding;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub const MAX_TEXT_SUBTITLE_BYTES: usize = 32 * 1024 * 1024;
const MAX_BINARY_SUBTITLE_BYTES: usize = 64 * 1024 * 1024;
static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(1);

const TEXT_EXTENSIONS: &[&str] = &[
    "ass", "srt", "ssa", "vtt", "smi", "sami", "lrc", "sub", "mpl", "mpl2",
];
const BINARY_EXTENSIONS: &[&str] = &["sup"];

pub fn is_subtitle_file_name(name: &str) -> bool {
    extension(name).is_some_and(|ext| {
        TEXT_EXTENSIONS.contains(&ext.as_str()) || BINARY_EXTENSIONS.contains(&ext.as_str())
    })
}

pub async fn prepare(
    source_uri: &str,
    file_name: &str,
    cache_dir: &str,
) -> Result<PreparedSubtitle> {
    let ext = extension(file_name).context("字幕文件没有可识别的扩展名")?;
    if !TEXT_EXTENSIONS.contains(&ext.as_str()) && !BINARY_EXTENSIONS.contains(&ext.as_str()) {
        anyhow::bail!("暂不支持的外挂字幕格式：.{ext}");
    }

    if BINARY_EXTENSIONS.contains(&ext.as_str()) {
        return prepare_binary(source_uri, file_name, cache_dir).await;
    }

    let bytes = if source_uri.starts_with("smb://") {
        crate::smb::read_file_limited(source_uri, MAX_TEXT_SUBTITLE_BYTES + 1).await?
    } else if source_uri.starts_with("http://") || source_uri.starts_with("https://") {
        crate::webdav::read_file_limited(source_uri, MAX_TEXT_SUBTITLE_BYTES + 1).await?
    } else {
        read_local_limited(source_uri, MAX_TEXT_SUBTITLE_BYTES + 1).await?
    };
    if bytes.len() > MAX_TEXT_SUBTITLE_BYTES {
        anyhow::bail!("字幕文件超过 32 MiB 安全上限");
    }

    // `.sub` can be either a text format (MicroDVD/MPL2) or VobSub MPEG data.
    // Preserve the old binary behavior rather than feeding binary bytes to an
    // encoding detector and creating a replacement-character-heavy text file.
    if ext == "sub" && looks_like_vobsub(&bytes) {
        return prepare_binary(source_uri, file_name, cache_dir).await;
    }

    let text = decode_text(&bytes).context("字幕编码无法可靠识别")?;
    validate_decoded_text(&text)?;
    let cache_dir = Path::new(cache_dir);
    tokio::fs::create_dir_all(cache_dir)
        .await
        .context("创建字幕缓存目录")?;
    let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let path = cache_dir.join(format!("subtitle-{id}.{ext}"));
    tokio::fs::write(&path, text.as_bytes())
        .await
        .context("写入 UTF-8 字幕缓存")?;
    let path = path.to_string_lossy().to_string();
    Ok(PreparedSubtitle {
        uri: path.clone(),
        temporary_path: Some(path),
        proxy_url: None,
    })
}

async fn prepare_binary(
    source_uri: &str,
    file_name: &str,
    cache_dir: &str,
) -> Result<PreparedSubtitle> {
    let proxy = if source_uri.starts_with("smb://") {
        Some(crate::smb::register_playable(source_uri).await?)
    } else if source_uri.starts_with("http://") || source_uri.starts_with("https://") {
        Some(crate::webdav::register_playable(source_uri).await?)
    } else {
        None
    };
    Ok(match proxy {
        Some(url) => PreparedSubtitle {
            uri: url.clone(),
            temporary_path: None,
            proxy_url: Some(url),
        },
        None => {
            // Local file: mpv's path-based open() is denied by the macOS
            // sandbox even inside a started security scope, so stage a copy
            // in the container cache like text subtitles.
            let bytes = read_local_limited(source_uri, MAX_BINARY_SUBTITLE_BYTES + 1).await?;
            if bytes.len() > MAX_BINARY_SUBTITLE_BYTES {
                anyhow::bail!("字幕文件超过安全上限");
            }
            let ext = extension(file_name).context("字幕文件没有可识别的扩展名")?;
            // Unique per preparation: two candidates can share a file name
            // (the video folder and its Subtitles/ subdirectory are both
            // scanned), and reusing the name made switching subtitles delete
            // the file mpv had just been handed.
            let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let cache_dir = std::path::Path::new(cache_dir);
            tokio::fs::create_dir_all(cache_dir)
                .await
                .context("创建字幕缓存目录")?;
            let path = cache_dir.join(format!("subtitle-{id}.{ext}.bin"));
            tokio::fs::write(&path, &bytes)
                .await
                .context("写入二进制字幕缓存")?;
            let path = path.to_string_lossy().to_string();
            PreparedSubtitle {
                uri: path.clone(),
                temporary_path: Some(path),
                proxy_url: None,
            }
        }
    })
}

async fn read_local_limited(path: &str, limit: usize) -> Result<Vec<u8>> {
    let path = local_path(path);
    let metadata = tokio::fs::metadata(&path).await.context("读取字幕信息")?;
    if metadata.len() > limit as u64 {
        anyhow::bail!("字幕文件超过 32 MiB 安全上限");
    }
    tokio::fs::read(path).await.context("读取本地字幕")
}

fn local_path(source: &str) -> PathBuf {
    source
        .strip_prefix("file://")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(source))
}

fn extension(name: &str) -> Option<String> {
    name.rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .filter(|ext| !ext.is_empty())
}

fn looks_like_vobsub(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0x00, 0x00, 0x01, 0xba])
        || bytes.starts_with(&[0x00, 0x00, 0x01, 0xbd])
        || bytes
            .windows(4)
            .take(4096)
            .any(|window| window == [0x00, 0x00, 0x01, 0xba] || window == [0x00, 0x00, 0x01, 0xbd])
}

fn decode_text(bytes: &[u8]) -> Result<String> {
    if let Some(rest) = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]) {
        return String::from_utf8(rest.to_vec()).context("无效 UTF-8 BOM 字幕");
    }
    if let Some(rest) = bytes.strip_prefix(&[0xff, 0xfe, 0x00, 0x00]) {
        return decode_utf32(rest, true);
    }
    if let Some(rest) = bytes.strip_prefix(&[0x00, 0x00, 0xfe, 0xff]) {
        return decode_utf32(rest, false);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xff, 0xfe]) {
        return decode_utf16(rest, true);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xfe, 0xff]) {
        return decode_utf16(rest, false);
    }
    // UTF-16 ASCII-heavy subtitle files are also technically valid UTF-8
    // byte sequences full of NULs. Detect that structure before accepting
    // strict UTF-8, otherwise BOM-less subtitles decode into control text.
    if let Some(little_endian) = likely_utf16(bytes) {
        if let Ok(text) = decode_utf16(bytes, little_endian) {
            return Ok(text);
        }
    }

    if let Ok(text) = std::str::from_utf8(bytes) {
        return Ok(text.to_string());
    }

    let mut detector = EncodingDetector::new(Iso2022JpDetection::Allow);
    detector.feed(bytes, true);
    let encoding = detector.guess(None, Utf8Detection::Allow);
    decode_legacy(encoding, bytes)
}

fn decode_utf16(bytes: &[u8], little_endian: bool) -> Result<String> {
    if bytes.len() % 2 != 0 {
        anyhow::bail!("UTF-16 字幕字节数不是偶数");
    }
    let words = bytes.chunks_exact(2).map(|chunk| {
        if little_endian {
            u16::from_le_bytes([chunk[0], chunk[1]])
        } else {
            u16::from_be_bytes([chunk[0], chunk[1]])
        }
    });
    std::char::decode_utf16(words)
        .collect::<std::result::Result<String, _>>()
        .map_err(|_| anyhow::anyhow!("UTF-16 字幕包含无效代理项"))
}

fn decode_utf32(bytes: &[u8], little_endian: bool) -> Result<String> {
    if bytes.len() % 4 != 0 {
        anyhow::bail!("UTF-32 字幕字节数不是四的倍数");
    }
    let mut text = String::with_capacity(bytes.len() / 2);
    for chunk in bytes.chunks_exact(4) {
        let value = if little_endian {
            u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
        } else {
            u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
        };
        text.push(char::from_u32(value).context("UTF-32 字幕包含无效码位")?);
    }
    Ok(text)
}

fn likely_utf16(bytes: &[u8]) -> Option<bool> {
    if bytes.len() < 8 || bytes.len() % 2 != 0 {
        return None;
    }
    let pairs = bytes.len() / 2;
    let even_nul = bytes.iter().step_by(2).filter(|&&b| b == 0).count();
    let odd_nul = bytes.iter().skip(1).step_by(2).filter(|&&b| b == 0).count();
    if odd_nul * 5 > pairs && even_nul * 20 < pairs {
        Some(true)
    } else if even_nul * 5 > pairs && odd_nul * 20 < pairs {
        Some(false)
    } else {
        None
    }
}

fn decode_legacy(encoding: &'static Encoding, bytes: &[u8]) -> Result<String> {
    encoding
        .decode_without_bom_handling_and_without_replacement(bytes)
        .map(|text| text.into_owned())
        .with_context(|| format!("{} 解码失败", encoding.name()))
}

fn validate_decoded_text(text: &str) -> Result<()> {
    if text.is_empty() {
        anyhow::bail!("字幕文件为空");
    }
    let controls = text
        .chars()
        .filter(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t' | '\u{feff}'))
        .count();
    if controls * 100 > text.chars().count().max(1) {
        anyhow::bail!("字幕包含过多二进制控制字符");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_utf16_little_endian_bom() {
        let mut bytes = vec![0xff, 0xfe];
        for word in "1\r\n00:00:01,000 --> 00:00:02,000\r\n入学式\r\n".encode_utf16() {
            bytes.extend_from_slice(&word.to_le_bytes());
        }
        assert!(decode_text(&bytes).unwrap().contains("入学式"));
    }

    #[test]
    fn decodes_utf16_big_endian_without_bom() {
        let mut bytes = Vec::new();
        for word in "1\n00:00:01,000 --> 00:00:02,000\n字幕\n".encode_utf16() {
            bytes.extend_from_slice(&word.to_be_bytes());
        }
        assert!(decode_text(&bytes).unwrap().contains("字幕"));
    }

    #[test]
    fn decodes_utf32_bom() {
        let mut bytes = vec![0x00, 0x00, 0xfe, 0xff];
        for ch in "1\n字幕\n".chars() {
            bytes.extend_from_slice(&(ch as u32).to_be_bytes());
        }
        assert_eq!(decode_text(&bytes).unwrap(), "1\n字幕\n");
    }

    #[test]
    fn keeps_strict_utf8_unchanged() {
        let source = "1\n00:00:01.000 --> 00:00:02.000\n测试\n";
        assert_eq!(decode_text(source.as_bytes()).unwrap(), source);
    }

    #[test]
    fn recognizes_vobsub_binary() {
        assert!(looks_like_vobsub(&[0, 0, 1, 0xba, 2, 3, 4]));
        assert!(!looks_like_vobsub(b"{1}{20}MicroDVD text"));
    }

    #[test]
    fn supports_expected_subtitle_extensions() {
        for name in [
            "a.srt", "a.ass", "a.ssa", "a.vtt", "a.smi", "a.lrc", "a.sub", "a.sup",
        ] {
            assert!(is_subtitle_file_name(name), "{name}");
        }
        assert!(!is_subtitle_file_name("a.idx"));
    }
}
