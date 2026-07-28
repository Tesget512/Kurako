import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import 'external_player.dart' show smbUncPath, ensureUncAuth;
import 'ios_platform.dart';

/// Abstracts where the library's video files live and how to reach them, so the
/// scan + playback code is identical across desktop (POSIX paths) and Android
/// (Storage Access Framework content:// URIs). Future: an SMB source.
abstract class MediaSource {
  /// "local" or "saf" — matches the Rust `source_type` column.
  String get sourceType;

  /// Let the user pick a library folder. Returns the folder's identifier
  /// (absolute path for local, tree URI for SAF), or null if cancelled.
  Future<String?> pickFolder();

  /// Enumerate all video files under [folderUri] as ScannedFile (uri +
  /// filename + folder-relative path). Empty for the local source, which lets
  /// Rust's walkdir do the enumeration instead.
  Future<List<ScannedFile>> enumerate(String folderUri);

  /// Resolve an episode's stored path into a URI media_kit can open. May open a
  /// file descriptor that must stay alive during playback — release it via
  /// [releasePlayable] when done.
  Future<PlayableHandle> resolvePlayable(Episode episode);

  /// External subtitle files sitting next to the video (same folder, same
  /// name stem, subtitle extension). Each candidate's uri is loadable by mpv.
  /// SAF has no directory access from a file URI, so it returns empty.
  Future<List<SubtitleCandidate>> listSubtitles(Episode episode) async =>
      const [];

  /// Pick the source appropriate for this episode's stored source_type.
  static MediaSource forEpisode(Episode e) => switch (e.sourceType) {
    'saf' => SafMediaSource(),
    'smb' => SmbMediaSource(),
    'webdav' => WebDavMediaSource(),
    _ => LocalMediaSource(),
  };

  /// Pick the default source for adding a new folder on this platform.
  static MediaSource forNewFolder() =>
      Platform.isAndroid ? SafMediaSource() : LocalMediaSource();
}

/// A resolved playable URI plus optional cleanup: SAF opens a file descriptor,
/// SMB registers a proxy token — both must be released after playback.
class PlayableHandle {
  final String uri;
  final int? fd;
  final bool networkProxy;
  bool _released = false;
  PlayableHandle(this.uri, {this.fd, this.networkProxy = false});

  Future<void> release() async {
    if (_released) return;
    _released = true;
    final openFd = fd;
    if (openFd != null) {
      try {
        await SafUtil().closeFileDescriptor(openFd);
      } catch (_) {}
    }
    if (networkProxy) {
      try {
        await rust.releaseNetworkUrl(url: uri);
      } catch (_) {}
    }
  }
}

/// Desktop (and any POSIX-path) source. Enumeration is delegated to Rust's
/// walkdir, so [enumerate] returns empty and callers use `scanAndMatch`.
class LocalMediaSource extends MediaSource {
  @override
  String get sourceType => 'local';

  @override
  Future<String?> pickFolder() => Platform.isIOS
      ? IosPlatform.pickLibraryFolder()
      : FilePicker.platform.getDirectoryPath();

  @override
  Future<List<ScannedFile>> enumerate(String folderUri) async => const [];

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    return PlayableHandle('file:///${episode.filePath}');
  }

  @override
  Future<List<SubtitleCandidate>> listSubtitles(Episode episode) async {
    return listLocalSubtitles(episode.filePath);
  }
}

/// Subtitle files next to a local video. Rust applies the same conservative
/// title + episode recognizer used for SMB streaming and downloaded sidecars.
Future<List<SubtitleCandidate>> listLocalSubtitles(String videoPath) async {
  final file = File(videoPath);
  final videoDir = file.parent;
  if (!await videoDir.exists()) return const [];
  final base = file.uri.pathSegments.last;
  final candidates = <SubtitleCandidate>[];
  final seen = <String>{};
  final directories = [videoDir, Directory(p.join(videoDir.path, 'Subtitles'))];
  for (final dir in directories) {
    if (!await dir.exists()) continue;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || !seen.add(e.path)) continue;
      final name = e.uri.pathSegments.last;
      candidates.add(SubtitleCandidate(fileName: name, uri: e.path));
    }
  }
  final matchingNames = (await rust.matchingSubtitleFileNames(
    videoName: base,
    subtitleNames: candidates.map((candidate) => candidate.fileName).toList(),
  )).toSet();
  final out = candidates
      .where((candidate) => matchingNames.contains(candidate.fileName))
      .toList();
  out.sort((a, b) => a.fileName.compareTo(b.fileName));
  return out;
}

/// Android Storage Access Framework source: pick a directory tree, recursively
/// list content:// documents, and open them by file descriptor for libmpv.
class SafMediaSource extends MediaSource {
  final _saf = SafUtil();

  static const _videoExts = {
    'mkv',
    'mp4',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'ts',
    'm2ts',
    'rmvb',
    'rm',
    'mpg',
    'mpeg',
    '3gp',
    'ogv',
  };

  @override
  String get sourceType => 'saf';

  @override
  Future<String?> pickFolder() async {
    final dir = await _saf.pickDirectory(
      writePermission: false,
      persistablePermission: true,
    );
    return dir?.uri;
  }

  @override
  Future<List<ScannedFile>> enumerate(String folderUri) async {
    final out = <ScannedFile>[];
    await _walk(folderUri, '', out);
    return out;
  }

  Future<void> _walk(
    String dirUri,
    String relativeParent,
    List<ScannedFile> out,
  ) async {
    late final List<SafDocumentFile> children;
    try {
      children = await _saf.list(dirUri);
    } catch (_) {
      return;
    }
    for (final c in children) {
      if (c.isDir) {
        final childRel = relativeParent.isEmpty
            ? c.name
            : '$relativeParent/${c.name}';
        await _walk(c.uri, childRel, out);
      } else if (_isVideo(c.name)) {
        out.add(
          ScannedFile(
            uri: c.uri,
            fileName: c.name,
            relativeParent: relativeParent,
          ),
        );
      }
    }
  }

  bool _isVideo(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExts.contains(name.substring(dot + 1).toLowerCase());
  }

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    // libmpv can read directly from a file descriptor: fd://<n>. The fd must be
    // kept open for the duration of playback and closed afterwards.
    final fd = await _saf.getFileDescriptor(episode.filePath);
    return PlayableHandle('fd://$fd', fd: fd);
  }
}

/// SMB network share source. Enumeration + playback go through Rust: the file
/// list comes from the Rust smb2 client, and playback is served by a local HTTP
/// proxy (libmpv can't play smb:// directly). Credentials live in Rust (set on
/// connect / restored at startup), so this class is a thin dispatcher.
class SmbMediaSource extends MediaSource {
  @override
  String get sourceType => 'smb';

  @override
  Future<String?> pickFolder() async {
    // SMB folders are added via the credentials dialog in settings, which calls
    // rust.smbConnect then addLibraryFolder directly — not through here.
    throw UnsupportedError('SMB folders are added via the settings dialog');
  }

  @override
  Future<List<ScannedFile>> enumerate(String folderUri) async {
    // folderUri is smb://host/share/subdir — enumerate the sub-path.
    final sub = _subPath(folderUri);
    return rust.smbEnumerate(subdir: sub);
  }

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    // Prefer a downloaded local copy — instant, no network, seekable.
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) {
      return PlayableHandle('file:///$local');
    }
    // Windows: play the UNC path directly through the OS SMB redirector, exactly
    // like the external player. Windows keeps ONE persistent authenticated
    // session per share and serves every file like a local file — so switching
    // episodes (same folder or across folders) reuses that session instead of
    // hammering the loopback proxy with a fresh smb2 connection per request,
    // which was starving the NAS session table and freezing playback.
    if (Platform.isWindows) {
      final unc = smbUncPath(episode.filePath);
      if (unc.startsWith(r'\\')) {
        await ensureUncAuth(unc);
        return PlayableHandle(unc);
      }
    }
    // Other platforms (Android/macOS/Linux) have no UNC: register with the local
    // proxy; libmpv plays the http:// URL.
    final url = await rust.smbPlayableUrl(smbUri: episode.filePath);
    if (Platform.isIOS) {
      // Validate the exact loopback route through iOS' own network stack before
      // giving it to libmpv. This turns the old endless spinner into a concrete
      // SMB/proxy error and also warms the authenticated SMB session.
      try {
        await _verifyIosLoopbackStream(url, sourceName: 'SMB');
      } catch (_) {
        // smbPlayableUrl already registered the proxy token; no PlayableHandle
        // is ever constructed on this path, so release it here or it leaks.
        try {
          await rust.releaseNetworkUrl(url: url);
        } catch (_) {}
        rethrow;
      }
    }
    return PlayableHandle(url, networkProxy: true);
  }

  @override
  Future<List<SubtitleCandidate>> listSubtitles(Episode episode) async {
    // If we have a local copy, use the local sidecar subtitles; else ask Rust
    // to enumerate their source URIs over SMB. The player prepares every text
    // sidecar as UTF-8 before handing it to mpv.
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) {
      return listLocalSubtitles(local);
    }
    // Windows: the UNC share behaves like a local directory once authenticated,
    // so enumerate sidecar subtitles with the normal filesystem walk (their UNC
    // paths load straight into mpv, no proxy).
    if (Platform.isWindows) {
      final unc = smbUncPath(episode.filePath);
      if (unc.startsWith(r'\\')) {
        try {
          await ensureUncAuth(unc);
          return await listLocalSubtitles(unc);
        } catch (_) {
          return const [];
        }
      }
    }
    try {
      return await rust.smbListSubtitles(smbUri: episode.filePath);
    } catch (_) {
      return const [];
    }
  }

  /// smb://host:port/share/sub/dir -> "sub/dir" (path within the share).
  static String _subPath(String smbUri) {
    final rest = smbUri.replaceFirst('smb://', '');
    final parts = rest.split('/');
    // parts[0]=host:port, parts[1]=share, rest=sub-path
    return parts.length > 2 ? parts.sublist(2).join('/') : '';
  }
}

class WebDavMediaSource extends MediaSource {
  @override
  String get sourceType => 'webdav';

  @override
  Future<String?> pickFolder() async {
    throw UnsupportedError('WebDAV folders are added through settings');
  }

  @override
  Future<List<ScannedFile>> enumerate(String folderUri) {
    return rust.webdavEnumerate(sourceUri: folderUri);
  }

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) return PlayableHandle('file:///$local');
    final url = await rust.webdavPlayableUrl(remoteUri: episode.filePath);
    if (Platform.isIOS) {
      try {
        await _verifyIosLoopbackStream(url, sourceName: 'WebDAV');
      } catch (_) {
        try {
          await rust.releaseNetworkUrl(url: url);
        } catch (_) {}
        rethrow;
      }
    }
    return PlayableHandle(url, networkProxy: true);
  }

  @override
  Future<List<SubtitleCandidate>> listSubtitles(Episode episode) async {
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) return listLocalSubtitles(local);
    try {
      return await rust.webdavListSubtitles(remoteUri: episode.filePath);
    } catch (_) {
      return const [];
    }
  }
}

/// Fetch one byte through the Rust loopback proxy using URLSession's Dart
/// equivalent. media_kit otherwise only reports a permanent "loading" state
/// when iOS cannot connect to 127.0.0.1 or the SMB server rejects the request.
Future<void> _verifyIosLoopbackStream(
  String url, {
  required String sourceName,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      final detail = await response.transform(utf8.decoder).join();
      throw HttpException(
        'HTTP ${response.statusCode}${detail.isEmpty ? '' : ': $detail'}',
        uri: Uri.parse(url),
      );
    }
    final firstChunk = await response
        .take(1)
        .toList()
        .timeout(const Duration(seconds: 15));
    if (firstChunk.isEmpty || firstChunk.first.isEmpty) {
      throw HttpException('$sourceName 串流未返回视频数据');
    }
  } on SocketException catch (e) {
    throw StateError('无法连接 iOS 本机 $sourceName 中转：${e.message}');
  } on TimeoutException {
    throw StateError('$sourceName 中转连接超时，请检查服务器与网络连接');
  } finally {
    client.close(force: true);
  }
}
