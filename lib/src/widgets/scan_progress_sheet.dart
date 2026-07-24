import 'package:flutter/material.dart';

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
  String? _error;
  final List<String> _smbErrors = [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // 1. Local (walkdir) folders: Rust enumerates + matches them all at once.
      final stream = rust.scanAndMatch(incremental: widget.incremental);
      await for (final p in stream) {
        if (!mounted) return;
        setState(() => _progress = p);
      }
      // 2. SAF (Android content://) and SMB (network share) folders: enumerated
      //    on the Dart/Rust side, then Rust recognizes/matches the file list.
      final folders = await rust.listLibraryFolders();
      for (final f in folders
          .where((f) => f.sourceType == 'saf' || f.sourceType == 'smb')) {
        if (!mounted) return;
        setState(() => _progress = ScanProgress(
              stage: 'scanning',
              current: 0,
              total: 0,
              message: '枚举 ${f.path}',
            ));
        final source = f.sourceType == 'smb'
            ? SmbMediaSource()
            : SafMediaSource();
        late final List<ScannedFile> files;
        try {
          files = await source.enumerate(f.path);
        } catch (_) {
          if (!mounted) return;
          // SMB connect/auth failures are common when the device is off the
          // local network. Record the folder-level error and continue scanning
          // other folders — don't abort the whole session.
          setState(() => _smbErrors.add(
                'SMB 连接失败（${_smbHost(f.path)}），请确认已连接到对应的局域网',
              ));
          continue;
        }
        final s2 = rust.scanFilesAndMatch(
          folderId: f.id,
          files: files,
          sourceType: f.sourceType,
        );
        await for (final p in s2) {
          if (!mounted) return;
          setState(() => _progress = p);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _done = true);
    }
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
          WindowDragArea(
            child: Text('扫描与匹配', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _done ? 1 : value),
          const SizedBox(height: 12),
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (_smbErrors.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final msg in _smbErrors)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.wifi_off_outlined,
                        size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        msg,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
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
