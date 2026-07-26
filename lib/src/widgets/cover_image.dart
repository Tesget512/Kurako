import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Bangumi's image CDN (lain.bgm.tv) rejects requests without a User-Agent and
/// serves some URLs over http. This helper normalises the URL and sends the
/// headers Bangumi expects, so covers actually load. When [url] is a local file
/// path (covers restored from an SMB snapshot), it's shown from disk instead.
/// When the Bangumi mirror is enabled, the image host is swapped to the mirror's
/// (bgmimg.anibt.net) so covers load on mainland networks too.
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

  static const _headers = {
    'User-Agent': 'Kurako/1.0',
    'Referer': 'https://bgm.tv/',
  };

  // Bangumi's official image CDN → the bangumi-proxy mirror's image host.
  static const _officialImgHost = 'lain.bgm.tv';
  static const _mirrorImgHost = 'bgmimg.anibt.net';

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
    var fixed = raw.startsWith('http://')
        ? raw.replaceFirst('http://', 'https://')
        : raw;
    // Route covers through whichever host matches the mirror setting.
    final mirror = ref.watch(bangumiMirrorProvider);
    if (mirror) {
      fixed = fixed.replaceFirst(_officialImgHost, _mirrorImgHost);
    } else {
      fixed = fixed.replaceFirst(_mirrorImgHost, _officialImgHost);
    }
    return CachedNetworkImage(
      imageUrl: fixed,
      httpHeaders: _headers,
      fit: fit,
      memCacheWidth: cacheWidth,
      placeholder: (_, _) =>
          Container(color: theme.colorScheme.surfaceContainerHighest),
      errorWidget: (_, _, _) => _fallback(theme, Icons.broken_image_outlined),
    );
  }

  Widget _fallback(ThemeData theme, IconData icon) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
