import 'dart:io';

import 'package:flutter/services.dart';

class MediaStoreReservation {
  final String uri;
  final int fd;
  final String displayName;

  const MediaStoreReservation({
    required this.uri,
    required this.fd,
    required this.displayName,
  });
}

class MediaStoreStat {
  final int size;
  final String displayName;

  const MediaStoreStat({required this.size, required this.displayName});
}

class MediaStoreSubtitle {
  final String uri;
  final String fileName;
  final int size;

  const MediaStoreSubtitle({
    required this.uri,
    required this.fileName,
    required this.size,
  });
}

/// Narrow Android bridge for app-owned MediaStore downloads. Rust still owns
/// network transfer; Kotlin only reserves/publishes/deletes public entries.
class AndroidMediaStoreStorage {
  static const MethodChannel _defaultChannel = MethodChannel(
    'kurako/android/media_store',
  );
  static const videoRelativePath = 'Download/Kurako';
  static const subtitleRelativePath = 'Download/Kurako/Subtitles';

  final MethodChannel channel;

  AndroidMediaStoreStorage({MethodChannel? channel})
    : channel = channel ?? _defaultChannel;

  static bool get supported {
    if (!Platform.isAndroid) return false;
    final match = RegExp(r'API (\d+)')
        .firstMatch(Platform.operatingSystemVersion);
    final sdk = int.tryParse(match?.group(1) ?? '');
    return sdk != null && sdk >= 29;
  }

  Future<MediaStoreReservation> reserveVideo(String displayName) =>
      _reserve(displayName, videoRelativePath, 'video/*');

  Future<MediaStoreReservation> reserveSubtitle(String displayName) =>
      _reserve(displayName, subtitleRelativePath, 'text/*');

  Future<MediaStoreReservation> _reserve(
    String displayName,
    String relativePath,
    String mimeTypeHint,
  ) async {
    final value = await channel.invokeMapMethod<String, Object?>('reserve', {
      'displayName': displayName,
      'relativePath': relativePath,
      'mimeTypeHint': mimeTypeHint,
    });
    final uri = value?['uri'] as String?;
    final fd = value?['fd'] as int?;
    final actualName = value?['displayName'] as String?;
    if (uri == null || fd == null || actualName == null) {
      throw const FileSystemException('MediaStore 未返回可写文件句柄');
    }
    return MediaStoreReservation(uri: uri, fd: fd, displayName: actualName);
  }

  Future<MediaStoreStat> stat(String uri) async {
    final value = await channel.invokeMapMethod<String, Object?>('stat', {
      'uri': uri,
    });
    return MediaStoreStat(
      size: value?['size'] as int? ?? 0,
      displayName: value?['displayName'] as String? ?? '',
    );
  }

  Future<void> publish(String uri) =>
      channel.invokeMethod<void>('publish', {'uri': uri});

  Future<void> abort(String uri) =>
      channel.invokeMethod<void>('abort', {'uri': uri});

  Future<void> deleteMedia(String uri, {required String videoName}) => channel
      .invokeMethod<void>('deleteMedia', {'uri': uri, 'videoName': videoName});

  Future<List<MediaStoreSubtitle>> listSubtitles(String videoName) async {
    final values =
        await channel.invokeListMethod<Map<Object?, Object?>>('listSubtitles', {
          'videoName': videoName,
        }) ??
        const [];
    return [
      for (final value in values)
        MediaStoreSubtitle(
          uri: value['uri'] as String? ?? '',
          fileName: value['fileName'] as String? ?? '',
          size: value['size'] as int? ?? 0,
        ),
    ].where((entry) => entry.uri.isNotEmpty).toList();
  }

  Future<String> copyToCache(String uri, String fileName) async {
    final path = await channel.invokeMethod<String>('copyToCache', {
      'uri': uri,
      'fileName': fileName,
    });
    if (path == null || path.isEmpty) {
      throw const FileSystemException('无法读取 MediaStore 字幕');
    }
    return path;
  }

  Future<void> closeDetachedFd(int fd) =>
      channel.invokeMethod<void>('closeDetachedFd', {'fd': fd});

  Future<void> cleanupPending() => channel.invokeMethod<void>('cleanupPending');
}
