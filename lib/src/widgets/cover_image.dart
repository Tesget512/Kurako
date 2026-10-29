import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../services/bangumi_mirror.dart';
import '../services/cover_repository.dart';

final coverRepositoryProvider = Provider<CoverRepository>(
  (ref) => CoverRepository.instance,
);

/// Whether a successful load should start the one-time cover reveal animation.
bool coverLoadNeedsFade({
  required bool fadeIn,
  required bool hasShownLoadedImage,
}) => fadeIn && !hasShownLoadedImage;

class CoverImage extends ConsumerWidget {
  final String? url;
  final BoxFit fit;
  final int? cacheWidth;
  final bool fadeIn;
  final bool waitForRouteTransition;

  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.fadeIn = false,
    this.waitForRouteTransition = false,
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
      fadeIn: fadeIn,
      waitForRouteTransition: waitForRouteTransition,
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
  final bool fadeIn;
  final bool waitForRouteTransition;
  const _RepositoryCover({
    super.key,
    required this.repository,
    required this.url,
    required this.headers,
    required this.fit,
    required this.cacheWidth,
    required this.fadeIn,
    required this.waitForRouteTransition,
  });

  @override
  State<_RepositoryCover> createState() => _RepositoryCoverState();
}

class _RepositoryCoverState extends State<_RepositoryCover> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _revealed = true;
  bool _hasShownLoadedImage = false;
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
        !mapEquals(oldWidget.headers, widget.headers) ||
        oldWidget.fadeIn != widget.fadeIn) {
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    final cached = widget.repository.peek(widget.url);
    if (cached != null) {
      // Match the 1.1.1 cache behavior: bytes already resident in memory are
      // painted immediately and must not replay a reveal transition.
      _bytes = cached;
      _failed = false;
      _revealed = true;
      _hasShownLoadedImage = true;
      return;
    }
    _bytes = null;
    _failed = false;
    _revealed = !widget.fadeIn;
    final url = widget.url;
    widget.repository
        .load(url, widget.headers)
        .then(
          (bytes) {
            unawaited(_showLoadedBytes(bytes, generation));
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

  Future<void> _showLoadedBytes(Uint8List bytes, int generation) async {
    if (!mounted || generation != _generation) return;
    // Only asynchronous repository loads reach this path. The first completed
    // load reveals smoothly instead of flashing the backdrop into place.
    final needsFade = coverLoadNeedsFade(
      fadeIn: widget.fadeIn,
      hasShownLoadedImage: _hasShownLoadedImage,
    );
    setState(() {
      _bytes = bytes;
      _failed = false;
      _hasShownLoadedImage = true;
      _revealed = !needsFade;
    });
    if (!needsFade) return;
    if (widget.waitForRouteTransition) {
      await _waitForRouteTransition();
      if (!mounted || generation != _generation) return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      setState(() => _revealed = true);
    });
  }

  Future<void> _waitForRouteTransition() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) return Future.value();
    final done = Completer<void>();
    void listener(AnimationStatus status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(listener);
      if (!done.isCompleted) done.complete();
    }

    animation.addStatusListener(listener);
    if (!animation.isAnimating) listener(animation.status);
    return done.future;
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
    return AnimatedOpacity(
      opacity: widget.fadeIn && !_revealed ? 0 : 1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Image.memory(
        bytes,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) =>
            _fallback(context, Icons.broken_image_outlined),
      ),
    );
  }
}
