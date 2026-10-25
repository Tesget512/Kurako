import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/security_scope.dart';
import '../state/providers.dart';
import '../widgets/window_caption.dart';

enum OnboardingPlatform { macos, windows, linux, ios, android, other }

OnboardingPlatform currentOnboardingPlatform() {
  if (Platform.isMacOS) return OnboardingPlatform.macos;
  if (Platform.isWindows) return OnboardingPlatform.windows;
  if (Platform.isLinux) return OnboardingPlatform.linux;
  if (Platform.isIOS) return OnboardingPlatform.ios;
  if (Platform.isAndroid) return OnboardingPlatform.android;
  return OnboardingPlatform.other;
}

bool get androidUsesLegacyPrivateStorage {
  if (!Platform.isAndroid) return false;
  final match = RegExp(r'API (\d+)')
      .firstMatch(Platform.operatingSystemVersion);
  final sdk = int.tryParse(match?.group(1) ?? '');
  return sdk != null && sdk < 29;
}

class OnboardingCopy {
  final String intro;
  final String? chooseFolderLabel;
  final String savedMessage;
  final String? locationDescription;
  final String accessSummary;

  const OnboardingCopy({
    required this.intro,
    required this.chooseFolderLabel,
    required this.savedMessage,
    required this.locationDescription,
    required this.accessSummary,
  });
}

OnboardingCopy onboardingCopyFor(
  OnboardingPlatform platform, {
  bool androidLegacy = false,
}) {
  return switch (platform) {
    OnboardingPlatform.macos => const OnboardingCopy(
      intro:
          '先确认下载位置。在 macOS 上，这一步会记住该文件夹的安全书签，'
          '否则应用重启后无法写入下载。',
      chooseFolderLabel: '选择文件夹并授权',
      savedMessage: '下载位置已设置，应用已记住该文件夹的访问权限。',
      locationDescription: null,
      accessSummary: '重新确认下载位置与 macOS 文件夹访问权限',
    ),
    OnboardingPlatform.windows ||
    OnboardingPlatform.linux => const OnboardingCopy(
      intro: '先确认视频下载保存的位置，之后也可以随时修改。',
      chooseFolderLabel: '选择文件夹',
      savedMessage: '下载位置已设置。',
      locationDescription: null,
      accessSummary: '重新确认默认下载位置',
    ),
    OnboardingPlatform.ios => const OnboardingCopy(
      intro: '视频会保存在“文件”App 中可见的 Kurako Downloads 文件夹。',
      chooseFolderLabel: null,
      savedMessage: '下载位置已设置。',
      locationDescription: 'Kurako Downloads（文件 App）',
      accessSummary: '查看 Files 可见的下载位置',
    ),
    OnboardingPlatform.android => OnboardingCopy(
      intro: androidLegacy
          ? 'Android 8–9 会把视频保存在应用私有下载目录，不需要额外存储权限。'
          : '视频会下载到系统 Download/Kurako 目录，不需要额外存储权限。',
      chooseFolderLabel: null,
      savedMessage: '下载位置已设置。',
      locationDescription: androidLegacy
          ? '应用私有下载目录（Android 8–9）'
          : 'Download/Kurako',
      accessSummary: androidLegacy ? '应用私有下载位置' : 'Download/Kurako',
    ),
    OnboardingPlatform.other => const OnboardingCopy(
      intro: '先确认视频下载保存的位置，之后也可以随时修改。',
      chooseFolderLabel: '选择文件夹',
      savedMessage: '下载位置已设置。',
      locationDescription: null,
      accessSummary: '重新确认默认下载位置',
    ),
  };
}

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
    if (currentOnboardingPlatform() == OnboardingPlatform.android ||
        currentOnboardingPlatform() == OnboardingPlatform.ios) {
      return;
    }
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
        picked = await FilePicker.getDirectoryPath();
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
        _message = onboardingCopyFor(
          currentOnboardingPlatform(),
          androidLegacy: androidUsesLegacyPrivateStorage,
        ).savedMessage;
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
    final copy = onboardingCopyFor(
      currentOnboardingPlatform(),
      androidLegacy: androidUsesLegacyPrivateStorage,
    );
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
                        copy.intro,
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
                                copy.locationDescription ?? downloadDir,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (copy.chooseFolderLabel case final label?)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: FilledButton.tonalIcon(
                                    onPressed: _busy
                                        ? null
                                        : _pickDownloadFolder,
                                    icon: const Icon(
                                      Icons.folder_open,
                                      size: 18,
                                    ),
                                    label: Text(label),
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
