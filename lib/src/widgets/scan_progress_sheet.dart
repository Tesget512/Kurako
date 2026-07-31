import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import 'window_caption.dart';

class ScanProgressSheet extends StatefulWidget {
  /// When true, folders whose files haven't changed since the last scan are
  /// skipped for speed. Full/clear rescans pass false.
  final bool incremental;
  const ScanProgressSheet({super.key, this.incremental = false});

  @override
  State<ScanProgressSheet> createState() => _ScanProgressSheetState();
}

class _ScanProgressSheetState extends State<ScanProgressSheet> {
  ScanProgress? _progress;
  bool _done = false;
  bool _cancelRequested = false;
  bool _sessionStarted = false;
  String? _error;
  final List<String> _networkErrors = [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      try {
        await WakelockPlus.enable();
      } catch (_) {
        // Scanning remains functional on a platform which cannot acquire a
        // display wake lock; the session cleanup still attempts to disable it.
      }
      await rust.scanSessionBegin(incremental: widget.incremental);
      _sessionStarted = true;
      final folders = await rust.listLibraryFolders();
      for (final f in folders) {
        if (_cancelRequested || await rust.scanSessionIsCancelled()) break;
        if (mounted) {
          setState(
            () => _progress = ScanProgress(
              stage: 'scanning',
              current: 0,
              total: 0,
              message: '枚举 ${f.path}',
            ),
          );
        }
        late final List<ScannedFile> files;
        try {
          if (f.sourceType == 'local') {
            final batch = await rust.enumerateLocalFolder(
              folderId: f.id,
              incremental: widget.incremental,
            );
            if (batch.skippedUnchanged) continue;
            files = batch.files;
          } else {
            final source = switch (f.sourceType) {
              'smb' => SmbMediaSource(),
              'webdav' => WebDavMediaSource(),
              _ => SafMediaSource(),
            };
            files = await source.enumerate(
              f.path,
              isCancelled: () => _cancelRequested,
            );
          }
        } catch (error) {
          if (_cancelRequested || await rust.scanSessionIsCancelled()) break;
          // SMB connect/auth failures are common when the device is off the
          // local network. Record the folder-level error and continue scanning
          // other folders. Existing names still reserve this folder's priority
          // so a temporary outage does not silently switch playback sources.
          await rust.claimExistingFolderFiles(folderId: f.id);
          final label = switch (f.sourceType) {
            'webdav' => 'WebDAV 读取失败（${Uri.tryParse(f.path)?.host ?? f.path}）',
            'smb' => 'SMB 连接失败（${_smbHost(f.path)}）',
            _ => '文件夹读取失败（${f.path}）',
          };
          if (mounted) {
            setState(() => _networkErrors.add('$label：$error'));
          }
          continue;
        }
        if (_cancelRequested || await rust.scanSessionIsCancelled()) break;
        final s2 = rust.scanFilesAndMatch(
          folderId: f.id,
          files: files,
          sourceType: f.sourceType,
        );
        await for (final p in s2) {
          if (mounted) setState(() => _progress = p);
        }
      }
      if (!_cancelRequested && !await rust.scanSessionIsCancelled()) {
        await for (final p in rust.finishScanAndMatch()) {
          if (mounted) setState(() => _progress = p);
        }
      }
    } catch (e) {
      if (!_cancelRequested && mounted) setState(() => _error = e.toString());
    } finally {
      if (_sessionStarted) {
        await rust.scanSessionClose();
        _sessionStarted = false;
      }
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      if (mounted) {
        setState(() => _done = true);
        if (_cancelRequested) Navigator.of(context).pop();
      }
    }
  }

  Future<void> _cancel() async {
    if (_done || _cancelRequested) {
      if (_done && mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _cancelRequested = true;
      _progress = const ScanProgress(
        stage: 'cancelling',
        current: 0,
        total: 0,
        message: '正在停止扫描…',
      );
    });
    if (_sessionStarted) await rust.scanSessionCancel();
  }

  /// Extract "host" from an `smb://host[:port]/share/...` path for display.
  static String _smbHost(String path) {
    final rest = path.replaceFirst('smb://', '');
    final slash = rest.indexOf('/');
    final hostPort = slash > 0 ? rest.substring(0, slash) : rest;
    // Strip the :port suffix for brevity.
    final colon = hostPort.lastIndexOf(':');
    return colon > 0 ? hostPort.substring(0, colon) : hostPort;
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final theme = Theme.of(context);

    String label;
    double? value;
    if (_error != null) {
      label = '扫描出错: $_error';
    } else if (p == null) {
      label = '准备中…';
    } else if (p.stage == 'scanning') {
      label = '扫描文件: ${p.message}';
      value = p.total > 0 ? p.current / p.total : null;
    } else if (p.stage == 'matching') {
      label = '匹配 Bangumi: ${p.message}';
      value = p.total > 0 ? p.current / p.total : null;
    } else if (p.stage == 'warning') {
      label = p.message;
      value = 1;
    } else if (p.stage == 'cancelling') {
      label = p.message;
    } else {
      label = '完成';
      value = 1;
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // This sheet blocks interaction with the rest of the window
          // (isDismissible/enableDrag both false) until the scan finishes, so
          // if the window ended up positioned awkwardly (partly off-screen,
          // behind another window) there was previously no way to drag it
          // into view to reach the "完成" button. The title text doubles as a
          // drag handle on desktop, same as the player/detail page toolbars.
          Row(
            children: [
              Expanded(
                child: WindowDragArea(
                  child: Text('扫描与匹配', style: theme.textTheme.titleLarge),
                ),
              ),
              IconButton(
                tooltip: _done ? '关闭' : '停止扫描',
                onPressed: _cancel,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _done ? 1 : value),
          const SizedBox(height: 12),
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (_networkErrors.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final msg in _networkErrors)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.wifi_off_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        msg,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _done ? () => Navigator.of(context).pop() : null,
            child: Text(_done ? '完成' : '进行中…'),
          ),
        ],
      ),
    );
  }
}
