import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path/path.dart' as p;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/security_scope.dart';
import 'external_player.dart' show smbUncPath, ensureUncAuth;
import 'ios_platform.dart';

class _SafScanCancelled implements Exception {
  const _SafScanCancelled();

  @override
  String toString() => '扫描已取消';
}

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
  Future<List<ScannedFile>> enumerate(
    String folderUri, {
    bool Function()? isCancelled,
  });

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

String localPlaybackUri(String path, {bool? windows}) =>
    Uri.file(path, windows: windows ?? Platform.isWindows).toString();

/// A resolved playable URI plus optional cleanup: SAF opens a file descriptor,
/// SMB registers a proxy token — both must be released after playback.
class PlayableHandle {
  final String uri;
  final int? fd;
  final bool networkProxy;
  final Future<void> Function()? onRelease;
  bool _released = false;
  PlayableHandle(
    this.uri, {
    this.fd,
    this.networkProxy = false,
    this.onRelease,
  });

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
    final releaseScope = onRelease;
    if (releaseScope != null) {
      try {
        await releaseScope();
      } catch (_) {}
    }
  }
}

/// Human-readable transport derived from the active handle, rather than only
/// the library row. Remote episodes may currently be reading a downloaded local
/// copy, in which case reporting SMB/WebDAV would be misleading.
String playbackTransportLabel(Episode episode, PlayableHandle? handle) {
  final uri = handle?.uri.toLowerCase();
  final readsLocalFile = uri?.startsWith('file:') == true;
  if (readsLocalFile &&
      (episode.sourceType == 'smb' || episode.sourceType == 'webdav')) {
    return '本地文件（已下载副本）';
  }
  return switch (episode.sourceType) {
    'smb' => 'SMB',
    'webdav' => 'WebDAV',
    'saf' => 'Android SAF',
    _ => '本地文件',
  };
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
  Future<List<ScannedFile>> enumerate(
    String folderUri, {
    bool Function()? isCancelled,
  }) async => const [];

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    var path = episode.filePath;
    // macOS sandbox: the folder picker's grant does not survive a relaunch;
    // start the retained security-scoped access before anything reads the
    // file. The player releases it with the handle.
    if (Platform.isMacOS) {
      // The bookmark is per FOLDER, so access() returns that folder as the
      // scope path. The playable file path must stay the episode's own file —
      // using the folder here made every previous transport (file, fd://,
      // loopback HTTP) try to open a directory.
      final scope = await SecurityScope.access(path);
      path = scope.path;
      // Kernel + mpv evidence: even with the scope active, mpv's own
      // path-based open() is denied (file-read-data on the volume root during
      // path resolution), and fd:// reaches mpv but its demuxer cannot probe
      // the descriptor ("Failed to recognize file format"). Serve the bytes
      // through the same loopback HTTP mechanism SMB/WebDAV already uses:
      // Rust opens the file (allowed while the scope is held) and mpv
      // plays a Range-capable http:// URL — no file-system access needed.
      var stage = 'register';
      String? url;
      try {
        final playableUrl = await rust.localPlayableUrl(path: path);
        url = playableUrl;
        stage = 'verify';
        await _verifyLoopbackStream(playableUrl, sourceName: '本地文件');
        return PlayableHandle(
          playableUrl,
          onRelease: () async {
            try {
              await rust.releaseNetworkUrl(url: playableUrl);
            } catch (_) {}
            await SecurityScope.release(scope.scopePath);
          },
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            'kurako/local-playback $stage failed: ${error.runtimeType}',
          );
        }
        if (url != null) {
          try {
            await rust.releaseNetworkUrl(url: url);
          } catch (_) {}
        }
        await SecurityScope.release(scope.scopePath);
        rethrow;
      }
    }
    return PlayableHandle(localPlaybackUri(path));
  }

  @override
  Future<List<SubtitleCandidate>> listSubtitles(Episode episode) async {
    var path = episode.filePath;
    if (Platform.isMacOS) {
      // listSubtitles runs while playback access is already active; keep it
      // that way for standalone reads by pairing a temporary access.
      final scope = await SecurityScope.access(path);
      try {
        return await listLocalSubtitles(scope.path);
      } finally {
        await SecurityScope.release(scope.scopePath);
      }
    }
    return listLocalSubtitles(path);
  }
}

/// A downloaded copy may live in a user-chosen folder, which on macOS needs an
/// active security scope. Holding it for the whole playback keeps seeks and
/// sidecar reads working; the handle releases it on stop.
Future<PlayableHandle> _localCopyHandle(String path) async {
  if (!Platform.isMacOS) return PlayableHandle(localPlaybackUri(path));
  final ScopedPath scope;
  try {
    scope = await SecurityScope.access(path);
  } on SecurityScopeException {
    // No bookmark (e.g. the default container folder): play the plain path.
    return PlayableHandle(localPlaybackUri(path));
  }
  return PlayableHandle(
    localPlaybackUri(scope.path),
    onRelease: () => SecurityScope.release(scope.scopePath),
  );
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
  Future<List<ScannedFile>> enumerate(
    String folderUri, {
    bool Function()? isCancelled,
  }) async {
    final out = <ScannedFile>[];
    await _walk(folderUri, '', out, isCancelled);
    return out;
  }

  Future<void> _walk(
    String dirUri,
    String relativeParent,
    List<ScannedFile> out,
    bool Function()? isCancelled,
  ) async {
    if (isCancelled?.call() == true) return;
    final children = await _listDirectoryForScan(dirUri, isCancelled);
    for (final c in children) {
      if (isCancelled?.call() == true) return;
      if (c.isDir) {
        final childRel = relativeParent.isEmpty
            ? c.name
            : '$relativeParent/${c.name}';
        await _walk(c.uri, childRel, out, isCancelled);
      } else if (_isVideo(c.name)) {
        out.add(
          ScannedFile(
            uri: c.uri,
            fileName: c.name,
            fileSize: c.length,
            relativeParent: relativeParent,
          ),
        );
      }
    }
  }

  Future<List<SafDocumentFile>> _listDirectoryForScan(
    String dirUri,
    bool Function()? isCancelled,
  ) async {
    final completer = Completer<List<SafDocumentFile>>();
    final startedAt = DateTime.now();
    final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (completer.isCompleted) return;
      if (isCancelled?.call() == true) {
        completer.completeError(const _SafScanCancelled());
      } else if (DateTime.now().difference(startedAt) >=
          const Duration(seconds: 20)) {
        completer.completeError(
          TimeoutException('Android 文件夹读取超过 20 秒', const Duration(seconds: 20)),
        );
      }
    });
    _saf
        .list(dirUri)
        .then(
          (children) {
            if (!completer.isCompleted) {
              completer.complete(children);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        );
    try {
      return await completer.future;
    } finally {
      timer.cancel();
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
  Future<List<ScannedFile>> enumerate(
    String folderUri, {
    bool Function()? isCancelled,
  }) async {
    // folderUri is smb://host/share/subdir — enumerate the sub-path.
    final sub = _subPath(folderUri);
    return rust.smbEnumerate(subdir: sub);
  }

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    // Prefer a downloaded local copy — instant, no network, seekable.
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) {
      return _localCopyHandle(local);
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
    // Other platforms (Android/macOS/Linux) have no UNC: register with the
    // local proxy; libmpv plays the http:// URL.
    final url = await rust.smbPlayableUrl(smbUri: episode.filePath);
    if (usesLoopbackProxy) {
      // Validate the exact loopback route through the platform network stack
      // before handing it to libmpv. This turns "SMB session + proxy + mpv
      // demux all at once" into "session established during warmup", which is
      // the difference between a slow first play and an apparently hung one.
      // Failures surface here as a concrete error instead of an mpv spinner.
      try {
        await _verifyLoopbackStream(url, sourceName: 'SMB');
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
  Future<List<ScannedFile>> enumerate(
    String folderUri, {
    bool Function()? isCancelled,
  }) {
    return rust.webdavEnumerate(sourceUri: folderUri);
  }

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    final local = await rust.downloadedLocalPath(smbUri: episode.filePath);
    if (local != null) return _localCopyHandle(local);
    final url = await rust.webdavPlayableUrl(remoteUri: episode.filePath);
    if (usesLoopbackProxy) {
      try {
        await _verifyLoopbackStream(url, sourceName: 'WebDAV');
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

/// Platforms whose remote playback goes through the Rust loopback HTTP proxy:
/// iOS and macOS have no UNC path, so libmpv plays `http://127.0.0.1/...`.
/// Windows plays UNC directly and Android uses SAF file descriptors.
bool get usesLoopbackProxy => Platform.isIOS || Platform.isMacOS;

/// Fetch one byte through the Rust loopback proxy using the Dart HTTP stack.
/// media_kit otherwise only reports a permanent "loading" state when the
/// platform cannot connect to 127.0.0.1 or the SMB server rejects the request.
/// Also warms the authenticated SMB session, so mpv's first demux reads find
/// an established connection instead of building one under load.
Future<void> _verifyLoopbackStream(
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
    throw StateError('无法连接本机 $sourceName 中转：${e.message}');
  } on TimeoutException {
    throw StateError('$sourceName 中转连接超时，请检查服务器与网络连接');
  } finally {
    client.close(force: true);
  }
}
