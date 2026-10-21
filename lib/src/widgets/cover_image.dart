import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../services/bangumi_mirror.dart';
import '../services/cover_repository.dart';

final coverRepositoryProvider = Provider<CoverRepository>(
  (ref) => CoverRepository.instance,
);

class CoverImage extends ConsumerWidget {
  final String? url;
  final BoxFit fit;
  final int? cacheWidth;

  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = url;
    if (raw == null || raw.isEmpty) {
      return _fallback(context, Icons.image_not_supported_outlined);
    }
    if (!raw.startsWith('http')) {
      return Image.file(
        File(raw),
        fit: fit,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) =>
            _fallback(context, Icons.broken_image_outlined),
      );
    }
    final service = BangumiMirrorService.instance;
    final mirror = ref.watch(bangumiMirrorStatusProvider).enabled;
    final selected = normalizeBangumiCoverUrl(raw, mirror: mirror);
    return _RepositoryCover(
      key: ValueKey(coverIdentity(raw)),
      repository: ref.watch(coverRepositoryProvider),
      url: selected,
      headers: service.headersForCover(selected),
      fit: fit,
      cacheWidth: cacheWidth,
    );
  }
}

Widget _fallback(BuildContext context, IconData icon) => ColoredBox(
  color: Theme.of(context).colorScheme.surfaceContainerHighest,
  child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
);

class _RepositoryCover extends StatefulWidget {
  final CoverRepository repository;
  final String url;
  final Map<String, String> headers;
  final BoxFit fit;
  final int? cacheWidth;
  const _RepositoryCover({
    super.key,
    required this.repository,
    required this.url,
    required this.headers,
    required this.fit,
    required this.cacheWidth,
  });

  @override
  State<_RepositoryCover> createState() => _RepositoryCoverState();
}

class _RepositoryCoverState extends State<_RepositoryCover> {
  Uint8List? _bytes;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_RepositoryCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.repository != widget.repository ||
        !mapEquals(oldWidget.headers, widget.headers)) {
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    _bytes = widget.repository.peek(widget.url) ?? _bytes;
    _failed = false;
    if (_bytes != null) return;
    final url = widget.url;
    widget.repository
        .load(url, widget.headers)
        .then(
          (bytes) {
            if (!mounted || generation != _generation) return;
            setState(() => _bytes = bytes);
          },
          onError: (Object error) {
            if (!mounted || generation != _generation) return;
            if (Uri.tryParse(url)?.host == bangumiMirrorImageHost) {
              BangumiMirrorService.instance.reportCoverFailure();
            }
            setState(() => _failed = true);
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return _failed
          ? _fallback(context, Icons.broken_image_outlined)
          : ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            );
    }
    return Image.memory(
      bytes,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) =>
          _fallback(context, Icons.broken_image_outlined),
    );
  }
}
