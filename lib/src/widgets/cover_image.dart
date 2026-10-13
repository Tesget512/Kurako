import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../services/bangumi_mirror.dart';

/// Bangumi's image CDN (lain.bgm.tv) rejects requests without a User-Agent and
/// serves some URLs over http. This helper normalises the URL and sends the
/// headers Bangumi expects, so covers actually load. When [url] is a local file
/// path (covers restored from an SMB snapshot), it's shown from disk instead.
/// When the Bangumi mirror is enabled, the image host is swapped to the mirror's
/// (lain.bangumi.vip) after API and image verification have both succeeded.
class CoverImage extends ConsumerWidget {
  final String? url;
  final BoxFit fit;

  /// Downsample the decoded image to this pixel width (memory + per-frame cost).
  /// Used by the blurred backdrop where full resolution is wasted anyway.
  final int? cacheWidth;

  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final raw = url;
    if (raw == null || raw.isEmpty) {
      return _fallback(theme, Icons.image_not_supported_outlined);
    }
    // A local file path (restored SMB cover) — show from disk.
    if (!raw.startsWith('http')) {
      final file = File(raw);
      return Image.file(
        file,
        fit: fit,
        cacheWidth: cacheWidth,
        errorBuilder: (_, e, s) =>
            _fallback(theme, Icons.broken_image_outlined),
      );
    }
    final service = BangumiMirrorService.instance;
    final mirror = ref.watch(bangumiMirrorProvider) && service.enabled;
    final fixed = normalizeBangumiCoverUrl(raw, mirror: mirror);
    if (mirror && Uri.tryParse(fixed)?.host == bangumiMirrorImageHost) {
      return _MirrorCoverImage(
        url: fixed,
        headers: service.headersForCover(fixed),
        fit: fit,
        cacheWidth: cacheWidth,
      );
    }
    return CachedNetworkImage(
      imageUrl: fixed,
      httpHeaders: service.headersForCover(fixed),
      fit: fit,
      memCacheWidth: cacheWidth,
      placeholder: (_, _) =>
          Container(color: theme.colorScheme.surfaceContainerHighest),
      errorWidget: (_, _, _) {
        if (mirror && Uri.tryParse(fixed)?.host == bangumiMirrorImageHost) {
          service.reportCoverFailure();
          return Tooltip(
            message: '镜像封面加载失败，请在设置中重新验证或关闭镜像回退官方。',
            child: _fallback(theme, Icons.broken_image_outlined),
          );
        }
        return _fallback(theme, Icons.broken_image_outlined);
      },
    );
  }

  Widget _fallback(ThemeData theme, IconData icon) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

// Mirror downloads must never follow Location with a challenge Cookie header.
class _MirrorCoverImage extends StatefulWidget {
  final String url;
  final Map<String, String> headers;
  final BoxFit fit;
  final int? cacheWidth;
  const _MirrorCoverImage({
    required this.url,
    required this.headers,
    required this.fit,
    required this.cacheWidth,
  });
  @override
  State<_MirrorCoverImage> createState() => _MirrorCoverImageState();
}

class _MirrorCoverImageState extends State<_MirrorCoverImage> {
  static final _cache = <String, Uint8List>{};
  static int _cacheBytes = 0;
  static const _budget = 16 * 1024 * 1024;
  late Future<Uint8List> _bytes;
  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(_MirrorCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !mapEquals(oldWidget.headers, widget.headers)) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() async {
    final url = widget.url;
    final headers = Map<String, String>.of(widget.headers);
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached;
      return cached;
    }
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.host != bangumiMirrorImageHost ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      throw const BangumiMirrorException('镜像图片域名无效。');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok ||
          response.headers.contentType?.primaryType != 'image') {
        throw const BangumiMirrorException(bangumiMirrorFailureMessage);
      }
      final bytes = await (() async {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (builder.length + chunk.length > 8 * 1024 * 1024) {
            throw const BangumiMirrorException('镜像图片超过大小限制。');
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      })().timeout(const Duration(seconds: 30));
      if (bytes.isEmpty) {
        throw const BangumiMirrorException(bangumiMirrorFailureMessage);
      }
      final previous = _cache.remove(url);
      if (previous != null) _cacheBytes -= previous.length;
      while (_cache.isNotEmpty && _cacheBytes + bytes.length > _budget) {
        _cacheBytes -= _cache.remove(_cache.keys.first)!.length;
      }
      _cache[url] = bytes;
      _cacheBytes += bytes.length;
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Widget _error(BuildContext context) {
    BangumiMirrorService.instance.reportCoverFailure();
    return Tooltip(
      message: '镜像封面加载失败，请在设置中重新验证或关闭镜像回退官方。',
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.broken_image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return _error(context);
      final bytes = snapshot.data;
      if (bytes == null) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        );
      }
      return Image.memory(
        bytes,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (context, _, _) => _error(context),
      );
    },
  );
}
