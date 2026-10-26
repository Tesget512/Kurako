import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/update_provider.dart';
import 'update_download_dialog.dart';

final updateNavigatorKey = GlobalKey<NavigatorState>();

/// Keeps the navigator stable and prompts once per version in this session.
class UpdateBannerHost extends ConsumerStatefulWidget {
  const UpdateBannerHost({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<UpdateBannerHost> createState() => _UpdateBannerHostState();
}

class _UpdateBannerHostState extends ConsumerState<UpdateBannerHost> {
  final _presented = <String>{};
  bool _scheduled = false;
  bool _open = false;

  void _schedule() {
    final state = ref.read(updateCheckProvider);
    if (_scheduled ||
        _open ||
        !state.showBanner ||
        _presented.contains(state.result!.release!.tagName)) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted) return;
      final current = ref.read(updateCheckProvider);
      if (!current.showBanner) return;
      final release = current.result!.release!;
      final context = updateNavigatorKey.currentState?.overlay?.context;
      if (context == null || !_presented.add(release.tagName)) return;
      _open = true;
      final download = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Kurako ${release.tagName} 可用'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: SelectableText(
                release.notes?.trim().isNotEmpty == true
                    ? release.notes!
                    : '暂时无法读取更新内容，可前往发布页面查看。',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  ref.read(updateCheckProvider.notifier).openRelease(),
              child: const Text('发布页面'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('下载'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ref.read(updateCheckProvider).result?.release?.tagName ==
          release.tagName) {
        ref.read(updateCheckProvider.notifier).dismissBanner();
        if (download == true && context.mounted) {
          await showUpdateDownload(context, ref);
        }
      }
      _open = false;
      if (mounted) _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(updateCheckProvider, (_, _) => _schedule());
    _schedule();
    return widget.child;
  }
}
