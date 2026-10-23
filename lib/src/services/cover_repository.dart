import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bangumi_mirror.dart';

typedef CoverFetcher =
    Future<Uint8List> Function(Uri uri, Map<String, String> headers);

String coverIdentity(String url) =>
    normalizeBangumiCoverUrl(url, mirror: false);

class CoverLoadException implements Exception {
  const CoverLoadException();
}

/// Disk identity is independent of the selected CDN. Request headers never
/// enter the key or leave the selected host.
class CoverRepository {
  static final instance = CoverRepository();
  final Future<Directory> Function() directory;
  final CoverFetcher fetch;
  final Future<void> Function(Uint8List) validate;
  final Future<Uint8List?> Function(String)? legacyLookup;
  final void Function()? onPersistenceFailure;
  final int memoryBudget;
  final int diskBudget;
  final _memory = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  int _memoryBytes = 0;
  Future<void> _diskWork = Future.value();
  DateTime? _lastTrim;
  final _warmQueue = <String>{};
  int _warmWorkers = 0;

  void warmLibrary(Iterable<String?> urls, BangumiMirrorService service) {
    _warmQueue.addAll(
      urls.whereType<String>().where((url) => url.startsWith('http')),
    );
    while (_warmWorkers < 2 && _warmQueue.isNotEmpty) {
      _warmWorkers++;
      unawaited(() async {
        try {
          while (_warmQueue.isNotEmpty) {
            final raw = _warmQueue.first;
            _warmQueue.remove(raw);
            final url = normalizeBangumiCoverUrl(raw, mirror: service.enabled);
            try {
              await load(url, service.headersForCover(url));
            } catch (_) {}
          }
        } finally {
          _warmWorkers--;
        }
      }());
    }
  }

  CoverRepository({
    Future<Directory> Function()? directory,
    CoverFetcher? fetch,
    Future<void> Function(Uint8List)? validate,
    Future<Uint8List?> Function(String)? legacyLookup,
    this.onPersistenceFailure,
    this.memoryBudget = 24 * 1024 * 1024,
    this.diskBudget = 256 * 1024 * 1024,
  }) : directory = directory ?? _defaultDirectory,
       fetch = fetch ?? _download,
       validate = validate ?? _validateImage,
       legacyLookup =
           legacyLookup ?? (directory == null ? _legacyLookup : null);

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'cover-cache-v2'),
  );

  static String fileKey(String identity) =>
      sha256.convert(utf8.encode(identity)).toString();

  Uint8List? peek(String url) {
    final identity = coverIdentity(url);
    final bytes = _memory.remove(identity);
    if (bytes != null) _memory[identity] = bytes;
    return bytes;
  }

  Future<Uint8List> load(String url, Map<String, String> headers) {
    final identity = coverIdentity(url);
    final cached = peek(identity);
    if (cached != null) return Future.value(cached);
    return _pending.putIfAbsent(identity, () async {
      try {
        final bytes = await _load(identity, Uri.parse(url), Map.of(headers));
        while (_memory.isNotEmpty &&
            _memoryBytes + bytes.length > memoryBudget) {
          _memoryBytes -= _memory.remove(_memory.keys.first)!.length;
        }
        if (bytes.length <= memoryBudget) {
          _memory[identity] = bytes;
          _memoryBytes += bytes.length;
        }
        return bytes;
      } finally {
        _pending.remove(identity);
      }
    });
  }

  Future<Uint8List> _load(
    String identity,
    Uri uri,
    Map<String, String> headers,
  ) async {
    Directory? dir;
    try {
      dir = await directory();
    } catch (_) {
      onPersistenceFailure?.call();
    }
    final file = dir == null ? null : File(p.join(dir.path, fileKey(identity)));
    try {
      if (file != null && await file.exists()) {
        if (await file.length() > 8 * 1024 * 1024) {
          throw const CoverLoadException();
        }
        final bytes = await file.readAsBytes();
        await validate(bytes);
        return bytes;
      }
    } catch (_) {
      try {
        await file?.delete();
      } catch (_) {}
    }
    Uint8List? old;
    try {
      old = await legacyLookup?.call(identity);
    } catch (_) {}
    if (old != null) {
      try {
        await validate(old);
        if (file != null) await _persist(file, old);
        return old;
      } catch (_) {}
    }
    final bytes = await fetch(uri, headers);
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const CoverLoadException();
    }
    await validate(bytes);
    if (file != null) await _persist(file, bytes);
    return bytes;
  }

  Future<void> _persist(File file, Uint8List bytes) async {
    final work = _diskWork.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.part');
        try {
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(file.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
        if (_lastTrim == null ||
            DateTime.now().difference(_lastTrim!) >
                const Duration(minutes: 5)) {
          _lastTrim = DateTime.now();
          await _trim(file.parent, keep: file.path);
        }
      } catch (_) {
        onPersistenceFailure?.call();
      }
    });
    _diskWork = work;
    await work;
  }

  Future<void> _trim(Directory dir, {required String keep}) async {
    final files = <({File file, FileStat stat})>[];
    var size = 0;
    final staleBefore = DateTime.now().subtract(const Duration(minutes: 10));
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (entity.path.endsWith('.part')) {
        // A crash between write and rename leaves an orphan that is never
        // counted or deleted; reclaim it once it is clearly abandoned.
        if (stat.modified.isBefore(staleBefore)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
        continue;
      }
      size += stat.size;
      files.add((file: entity, stat: stat));
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    for (final entry in files) {
      if (size <= diskBudget) break;
      if (entry.file.path == keep) continue;
      await entry.file.delete();
      size -= entry.stat.size;
    }
  }

  static Future<void> _validateImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  static Future<Uint8List?> _legacyLookup(String identity) async {
    final aliases = {
      identity,
      normalizeBangumiCoverUrl(identity, mirror: true),
    };
    final support = await getApplicationSupportDirectory();
    for (final alias in aliases) {
      final old = File(p.join(support.path, 'covers', fileKey(alias)));
      try {
        if (await old.exists() && await old.length() <= 8 * 1024 * 1024) {
          final bytes = await old.readAsBytes();
          await _validateImage(bytes);
          return bytes;
        }
        final cached = await DefaultCacheManager().getFileFromCache(alias);
        if (cached != null && await cached.file.length() <= 8 * 1024 * 1024) {
          final bytes = await cached.file.readAsBytes();
          await _validateImage(bytes);
          return bytes;
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<Uint8List> _download(
    Uri uri,
    Map<String, String> headers,
  ) async {
    const hosts = {
      'lain.bgm.tv',
      'bgmimg.anibt.net',
      'lain.bangumi.lat',
      bangumiMirrorImageHost,
    };
    if (uri.scheme != 'https' ||
        !hosts.contains(uri.host) ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty) {
      throw const CoverLoadException();
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        var target = uri;
        for (var redirect = 0; redirect <= 3; redirect++) {
          final request = await client.getUrl(target);
          request.followRedirects = false;
          headers.forEach(request.headers.set);
          final response = await request.close();
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (uri.host == bangumiMirrorImageHost || location == null) {
              throw const CoverLoadException();
            }
            final next = target.resolve(location);
            if (next.scheme != 'https' ||
                next.host != uri.host ||
                next.userInfo.isNotEmpty ||
                next.hasPort) {
              throw const CoverLoadException();
            }
            target = next;
            continue;
          }
          if (response.statusCode != HttpStatus.ok ||
              response.headers.contentType?.primaryType != 'image') {
            throw const CoverLoadException();
          }
          final result = BytesBuilder(copy: false);
          await for (final chunk in response) {
            if (result.length + chunk.length > 8 * 1024 * 1024) {
              throw const CoverLoadException();
            }
            result.add(chunk);
          }
          return result.takeBytes();
        }
        throw const CoverLoadException();
      })().timeout(const Duration(seconds: 40));
    } finally {
      client.close(force: true);
    }
  }
}
