import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Bangumi's image CDN (lain.bgm.tv) rejects requests without a User-Agent and
/// serves some URLs over http. This helper normalises the URL and sends the
/// headers Bangumi expects, so covers actually load. When [url] is a local file
/// path (covers restored from an SMB snapshot), it's shown from disk instead.
class CoverImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  const CoverImage({super.key, required this.url, this.fit = BoxFit.cover});

  static const _headers = {
    'User-Agent': 'animebdplayer/1.0 (https://github.com/animebd/anime-bd-player)',
    'Referer': 'https://bgm.tv/',
  };

  @override
  Widget build(BuildContext context) {
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
        errorBuilder: (_, e, s) =>
            _fallback(theme, Icons.broken_image_outlined),
      );
    }
    final fixed = raw.startsWith('http://')
        ? raw.replaceFirst('http://', 'https://')
        : raw;
    return CachedNetworkImage(
      imageUrl: fixed,
      httpHeaders: _headers,
      fit: fit,
      placeholder: (_, _) =>
          Container(color: theme.colorScheme.surfaceContainerHighest),
      errorWidget: (_, _, _) =>
          _fallback(theme, Icons.broken_image_outlined),
    );
  }

  Widget _fallback(ThemeData theme, IconData icon) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
