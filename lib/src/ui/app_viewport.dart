import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/window_caption.dart';
import 'portrait_scope.dart';

final portraitPreviewProvider = NotifierProvider<PortraitPreviewNotifier, bool>(
  PortraitPreviewNotifier.new,
);

/// A session-only inspection mode, never exported to another device.
class PortraitPreviewNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

class AppViewport extends ConsumerWidget {
  const AppViewport({
    super.key,
    required this.desktop,
    required this.scalePercent,
    required this.child,
  });
  final bool desktop;
  final int scalePercent;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portrait = desktop && ref.watch(portraitPreviewProvider);
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewFit = math.min(
          1.0,
          math.min(
            constraints.maxWidth / 390,
            math.max(1, constraints.maxHeight - 48) / 844,
          ),
        );
        final width = portrait ? 390 * previewFit : constraints.maxWidth;
        final height = portrait ? 844 * previewFit : constraints.maxHeight;
        final scale = scalePercent / 100.0;
        final logical = portrait
            ? Size(390 / scale, 844 / scale)
            : Size(width / scale, height / scale);
        // Keep this entire ancestor chain stable so toggling does not remount Navigator.
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: portrait ? 36 : 0),
                  child: Center(
                    child: SizedBox(
                      key: const ValueKey('app-viewport'),
                      width: width,
                      height: height,
                      child: ClipRect(
                        child: FittedBox(
                          fit: BoxFit.fill,
                          child: SizedBox(
                            width: logical.width,
                            height: logical.height,
                            child: MediaQuery(
                              data: mq.copyWith(
                                size: logical,
                                devicePixelRatio:
                                    mq.devicePixelRatio *
                                    scale *
                                    (portrait ? previewFit : 1),
                              ),
                              child: PortraitPreviewScope(
                                enabled: portrait,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (portrait)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 36,
                  child: _PreviewCaption(),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PreviewCaption extends ConsumerStatefulWidget {
  const _PreviewCaption();
  @override
  ConsumerState<_PreviewCaption> createState() => _PreviewCaptionState();
}

class _PreviewCaptionState extends ConsumerState<_PreviewCaption> {
  late final _entry = OverlayEntry(
    builder: (context) => Material(
      child: WindowCaption(
        title: 'Kurako',
        actions: [
          IconButton(
            tooltip: '退出竖版预览',
            onPressed: () =>
                ref.read(portraitPreviewProvider.notifier).set(false),
            icon: const Icon(Icons.close_fullscreen_rounded),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
