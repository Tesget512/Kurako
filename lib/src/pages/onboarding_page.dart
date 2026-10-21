import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/security_scope.dart';
import '../state/providers.dart';
import '../widgets/window_caption.dart';

/// First-run setup.
///
/// The macOS sandbox only keeps a folder reachable across launches when a
/// security-scoped bookmark was created for it. Picking the download folder
/// here is what creates that bookmark, so downloads cannot silently fail on
/// the next launch. The same screen is reachable again from Maintenance.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key, this.standalone = false});

  /// True when opened as a normal route (from Maintenance) instead of the
  /// first-run gate, which controls whether closing is allowed.
  final bool standalone;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  bool _busy = false;
  String? _message;
  String? _error;

  Future<void> _pickDownloadFolder() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      // macOS needs the panel's own URL to create the bookmark, so it goes
      // through the native bridge; other platforms keep the normal picker.
      String? picked;
      if (Platform.isMacOS) {
        picked = await SecurityScope.pickAndRetainFolder();
      } else {
        picked = await FilePicker.platform.getDirectoryPath();
        if (picked != null) {
          // Non-macOS has no bookmark; retain is a no-op there.
          await SecurityScope.retain(picked);
        }
      }
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await ref.read(downloadDirProvider.notifier).set(picked);
      if (!mounted) return;
      setState(() {
        _message = '下载位置已设置，应用已记住该文件夹的访问权限。';
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    await ref.read(onboardingCompletedProvider.notifier).complete();
    if (!mounted) return;
    if (widget.standalone) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloadDir = effectiveDownloadDir(ref.watch(downloadDirProvider));
    return Scaffold(
      body: Column(
        children: [
          WindowCaption(title: widget.standalone ? '初始设置' : '欢迎使用 Kurako'),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.play_circle_outline,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.standalone ? '初始设置' : '欢迎使用 Kurako',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '先确认下载位置。在 macOS 上，这一步会记住该文件夹的访问权限，'
                        '否则应用重启后无法写入下载。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('下载位置', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 6),
                              SelectableText(
                                downloadDir,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.tonalIcon(
                                  onPressed: _busy ? null : _pickDownloadFolder,
                                  icon: const Icon(Icons.folder_open, size: 18),
                                  label: const Text('选择文件夹并授权'),
                                ),
                              ),
                              if (_message != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  _message!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  _error!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '之后也可以在「维护」中重新进入此页面调整。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _finish,
                        child: Text(widget.standalone ? '完成' : '开始使用'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
