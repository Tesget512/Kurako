import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/update_provider.dart';
import 'update_download_dialog.dart';

/// The banner is mounted inside `MaterialApp.builder`, which sits *above* the
/// navigator, so its own context has no `Navigator`. This key reaches the real
/// navigator so the download dialog can be pushed from the banner.
final updateNavigatorKey = GlobalKey<NavigatorState>();

/// Mount inside MaterialApp.builder, wrapping the navigator child before scaling.
/// This overlay does not resize the navigator or require a ScaffoldMessenger.
/// Only the compact banner itself receives pointer events.
class UpdateBannerHost extends ConsumerWidget {
  const UpdateBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateCheckProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (state.showBanner)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: const _UpdateBanner(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UpdateBanner extends ConsumerStatefulWidget {
  const _UpdateBanner();

  @override
  ConsumerState<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<_UpdateBanner> {
  Future<void> _openDownload() async {
    final dialogContext = updateNavigatorKey.currentState?.overlay?.context;
    if (dialogContext == null) return;
    await showUpdateDownload(dialogContext, ref);
  }

  @override
  Widget build(BuildContext context) {
    final release = ref.watch(updateCheckProvider).result!.release!;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.system_update_alt, color: colors.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Kurako ${release.tagName} 可用',
                style: TextStyle(color: colors.onSecondaryContainer),
              ),
            ),
            TextButton(onPressed: _openDownload, child: const Text('下载')),
            Semantics(
              label: '忽略此版本提示',
              button: true,
              child: IconButton(
                key: const ValueKey('dismiss-update-banner'),
                onPressed: () =>
                    ref.read(updateCheckProvider.notifier).dismissBanner(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
