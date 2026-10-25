import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update.dart';
import '../services/app_update_download.dart';
import '../services/ios_platform.dart';
import '../state/update_provider.dart';

/// Lives outside the dialog so a download keeps running after the dialog is
/// closed, and so its state survives reopening.
final updateDownloadProvider =
    NotifierProvider<UpdateDownloadNotifier, UpdateDownloadState>(
      () => UpdateDownloadNotifier(AppUpdateDownloader()),
    );

class UpdateDownloadState {
  const UpdateDownloadState({
    this.tagName,
    this.received = 0,
    this.total = 0,
    this.running = false,
    this.path,
    this.message,
  });

  /// The release this state belongs to. Prevents a finished download from the
  /// previous version being shown for a newer one.
  final String? tagName;
  final int received;
  final int total;
  final bool running;
  final String? path;
  final String? message;
}

class UpdateDownloadNotifier extends Notifier<UpdateDownloadState> {
  UpdateDownloadNotifier([this.downloader]);

  final AppUpdateDownloader? downloader;
  UpdateDownloadOperation? _operation;
  bool _disposed = false;
  late final AppUpdateDownloader _downloader;

  @override
  UpdateDownloadState build() {
    _downloader = downloader ?? AppUpdateDownloader();
    ref.onDispose(() {
      _disposed = true;
      cancel();
    });
    return const UpdateDownloadState();
  }

  /// Reset stale results when the dialog opens for a different release.
  void prepare(AppUpdateRelease release) {
    if (_disposed || state.running || state.tagName == release.tagName) return;
    state = UpdateDownloadState(tagName: release.tagName);
  }

  Future<void> start(AppUpdateRelease release, AppUpdateAsset asset) async {
    if (_disposed || _operation != null) return;
    final operation = UpdateDownloadOperation();
    _operation = operation;
    state = UpdateDownloadState(
      tagName: release.tagName,
      running: true,
      total: asset.size,
    );
    try {
      final path = await _downloader.download(
        release: release,
        asset: asset,
        operation: operation,
        onProgress: (received, total) {
          if (_disposed) return;
          state = UpdateDownloadState(
            tagName: release.tagName,
            running: true,
            received: received,
            total: total,
          );
        },
      );
      if (_disposed) return;
      state = UpdateDownloadState(
        tagName: release.tagName,
        path: path,
        message: Platform.isIOS ? '下载完成，请自行签名后侧载。' : '下载完成，可使用下载包安装更新。',
      );
    } catch (error) {
      if (_disposed) return;
      state = UpdateDownloadState(
        tagName: release.tagName,
        message: error is UpdateDownloadCancelled
            ? '已取消下载。'
            : error is FormatException
            ? error.message
            : '下载失败，请检查网络或代理后重试。',
      );
    } finally {
      _operation = null;
    }
  }

  void cancel() => _operation?.cancel();
}

/// Opens the update dialog for the release currently offered by the checker.
Future<void> showUpdateDownload(BuildContext context, WidgetRef ref) async {
  final release = ref.read(updateCheckProvider).result?.release;
  if (release == null) return;
  ref.read(updateDownloadProvider.notifier).prepare(release);
  final target = currentUpdateTarget();
  final assets = compatibleUpdateAssets(
    release,
    platform: target.platform,
    architecture: target.architecture,
  );
  await showDialog<void>(
    context: context,
    builder: (_) => _UpdateDownloadDialog(release: release, assets: assets),
  );
}

class _UpdateDownloadDialog extends ConsumerStatefulWidget {
  const _UpdateDownloadDialog({required this.release, required this.assets});

  final AppUpdateRelease release;
  final List<AppUpdateAsset> assets;

  @override
  ConsumerState<_UpdateDownloadDialog> createState() =>
      _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends ConsumerState<_UpdateDownloadDialog> {
  bool _busy = false;
  String? _actionMessage;

  /// Reveals the downloaded package to the user. Nothing is installed or
  /// signed automatically: Android exports a copy through the system picker,
  /// iOS opens the share sheet (which already carries the iPad popover fix),
  /// and desktop opens the containing folder.
  Future<void> _accessFile(String path) async {
    setState(() {
      _busy = true;
      _actionMessage = null;
    });
    try {
      if (Platform.isIOS) {
        if (!await IosPlatform.shareVideo(path)) {
          throw const FileSystemException('share sheet unavailable');
        }
      } else if (Platform.isAndroid) {
        final destination = await FilePicker.saveFile(
          dialogTitle: '导出更新包',
          fileName: p.basename(path),
          bytes: await File(path).readAsBytes(),
        );
        if (destination != null && mounted) {
          setState(() => _actionMessage = '更新包已导出，可在系统文件管理器中打开安装。');
        }
      } else if (!await launchUrl(Uri.directory(File(path).parent.path))) {
        throw const FileSystemException('directory unavailable');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _actionMessage = '无法打开或导出文件，请重试；已下载的更新包仍保留。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateDownloadProvider);
    final notifier = ref.read(updateDownloadProvider.notifier);
    final title = state.tagName ?? widget.release.tagName;
    return AlertDialog(
      title: Text('更新至 $title'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.running) ...[
                LinearProgressIndicator(
                  value: state.total > 0 ? state.received / state.total : null,
                ),
                const SizedBox(height: 12),
                Text(
                  '${(state.received / 1048576).toStringAsFixed(1)} / '
                  '${(state.total / 1048576).toStringAsFixed(1)} MiB',
                ),
              ] else if (state.path != null) ...[
                Text(state.message!),
                const SizedBox(height: 12),
                SelectableText(state.path!),
                TextButton.icon(
                  onPressed: _busy ? null : () => _accessFile(state.path!),
                  icon: Icon(
                    Platform.isIOS || Platform.isAndroid
                        ? Icons.ios_share
                        : Icons.folder_open,
                  ),
                  label: Text(
                    Platform.isIOS
                        ? '分享更新包'
                        : Platform.isAndroid
                        ? '导出更新包'
                        : '打开所在目录',
                  ),
                ),
                if (_actionMessage != null) Text(_actionMessage!),
              ] else ...[
                if (state.message != null) Text(state.message!),
                if (widget.assets.isEmpty) const Text('此版本未提供适用于当前设备的更新包。'),
                for (final asset in widget.assets)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(asset.name),
                    subtitle: Text(
                      '${(asset.size / 1048576).toStringAsFixed(1)} MiB',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.download),
                      tooltip: '下载更新包',
                      onPressed: () => notifier.start(widget.release, asset),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (state.running)
          TextButton(onPressed: notifier.cancel, child: const Text('取消下载')),
        TextButton(
          onPressed: () async {
            final opened = await ref
                .read(updateCheckProvider.notifier)
                .openRelease();
            if (!opened && mounted) {
              setState(() => _actionMessage = '无法打开版本详情，请检查默认浏览器。');
            }
          },
          child: const Text('版本详情'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(state.running ? '后台下载' : '关闭'),
        ),
      ],
    );
  }
}
