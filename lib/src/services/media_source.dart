import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import '../rust/models.dart';

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

  /// Pick the source appropriate for this episode's stored source_type.
  static MediaSource forEpisode(Episode e) =>
      e.sourceType == 'saf' ? SafMediaSource() : LocalMediaSource();

  /// Pick the default source for adding a new folder on this platform.
  static MediaSource forNewFolder() =>
      Platform.isAndroid ? SafMediaSource() : LocalMediaSource();
}

/// A resolved playable URI plus an optional open file descriptor to close after
/// playback (SAF). For local files there's nothing to release.
class PlayableHandle {
  final String uri;
  final int? _fd;
  PlayableHandle(this.uri, [this._fd]);

  Future<void> release() async {
    if (_fd != null) {
      try {
        await SafUtil().closeFileDescriptor(_fd);
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
  Future<String?> pickFolder() => FilePicker.platform.getDirectoryPath();

  @override
  Future<List<ScannedFile>> enumerate(String folderUri) async => const [];

  @override
  Future<PlayableHandle> resolvePlayable(Episode episode) async {
    return PlayableHandle('file:///${episode.filePath}');
  }
}

/// Android Storage Access Framework source: pick a directory tree, recursively
/// list content:// documents, and open them by file descriptor for libmpv.
class SafMediaSource extends MediaSource {
  final _saf = SafUtil();

  static const _videoExts = {
    'mkv', 'mp4', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'ts', 'm2ts',
    'rmvb', 'rm', 'mpg', 'mpeg', '3gp', 'ogv',
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
        final childRel =
            relativeParent.isEmpty ? c.name : '$relativeParent/${c.name}';
        await _walk(c.uri, childRel, out);
      } else if (_isVideo(c.name)) {
        out.add(ScannedFile(
          uri: c.uri,
          fileName: c.name,
          relativeParent: relativeParent,
        ));
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
    return PlayableHandle('fd://$fd', fd);
  }
}
