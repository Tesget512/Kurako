import 'package:flutter/material.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';

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
      // 2. SAF (Android) folders: Dart enumerates the content:// tree, then Rust
      //    recognizes/matches the file list.
      final folders = await rust.listLibraryFolders();
      final saf = SafMediaSource();
      for (final f in folders.where((f) => f.sourceType == 'saf')) {
        if (!mounted) return;
        setState(() => _progress = ScanProgress(
              stage: 'scanning',
              current: 0,
              total: 0,
              message: '枚举 ${f.path}',
            ));
        final files = await saf.enumerate(f.path);
        final s2 = rust.scanFilesAndMatch(folderId: f.id, files: files);
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
          Text('扫描与匹配', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _done ? 1 : value),
          const SizedBox(height: 12),
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
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
