import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ui/page_components.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import '../widgets/window_caption.dart';

class DuplicateCheckPage extends ConsumerStatefulWidget {
  const DuplicateCheckPage({super.key});

  @override
  ConsumerState<DuplicateCheckPage> createState() => _DuplicateCheckPageState();
}

class _DuplicateCheckPageState extends ConsumerState<DuplicateCheckPage> {
  StreamSubscription<DuplicateCheckProgress>? _subscription;
  int? _token;
  bool _running = false;
  bool _done = false;
  bool _cancelRequested = false;
  int _current = 0;
  int _total = 0;
  String _currentFile = '';
  String? _error;
  final _groups = <DuplicateCandidateGroup>[];
  final _warnings = <String>[];

  @override
  Widget build(BuildContext context) {
    final hasActiveDownloads = ref
        .watch(downloadManagerProvider)
        .any((task) => task.active);
    return Scaffold(
      appBar: const SysAppBar(title: Text('疑似重复检查')),
      body: KurakoPageList(
        maxWidth: 840,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _statusText(hasActiveDownloads),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 16),
              if (_running)
                IconButton.filledTonal(
                  tooltip: '取消检查',
                  onPressed: _cancelRequested ? null : _cancel,
                  icon: const Icon(Icons.close),
                )
              else
                FilledButton.icon(
                  onPressed: hasActiveDownloads ? null : _start,
                  icon: const Icon(Icons.manage_search_outlined),
                  label: Text(_done ? '重新检查' : '开始检查'),
                ),
            ],
          ),
          if (_running) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _total > 0 ? _current / _total : null,
            ),
            if (_currentFile.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _currentFile,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              '检查失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_done && !_cancelRequested) ...[
            const SizedBox(height: 20),
            Text(
              _groups.isEmpty ? '未发现疑似重复文件' : '发现 ${_groups.length} 组疑似重复',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '结果基于文件大小和四处内容抽样，需要人工确认。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_groups.isNotEmpty) ...[
            const Divider(height: 32),
            for (var index = 0; index < _groups.length; index++)
              _DuplicateGroupTile(index: index, group: _groups[index]),
          ],
          if (_warnings.isNotEmpty) ...[
            const Divider(height: 32),
            Text('未能检查', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final warning in _warnings)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_outlined),
                title: Text(warning),
              ),
          ],
        ],
      ),
    );
  }

  String _statusText(bool hasActiveDownloads) {
    if (hasActiveDownloads && !_running) return '请先结束正在进行的下载';
    if (_cancelRequested && _running) return '正在取消…';
    if (_running) {
      return _total > 0 ? '已检查 $_current / $_total' : '正在筛选候选文件…';
    }
    if (_cancelRequested) return '检查已取消';
    if (_done) return '检查完成';
    return '仅在本页手动执行，不参与媒体库扫描';
  }

  Future<void> _start() async {
    if (_running ||
        ref.read(downloadManagerProvider).any((task) => task.active)) {
      return;
    }
    await _subscription?.cancel();
    setState(() {
      _running = true;
      _done = false;
      _cancelRequested = false;
      _current = 0;
      _total = 0;
      _currentFile = '';
      _error = null;
      _groups.clear();
      _warnings.clear();
    });
    try {
      final token = (await rust.duplicateCheckBegin()).toInt();
      if (!mounted) {
        await rust.duplicateCheckCancel(token: token);
        return;
      }
      _token = token;
      _subscription = rust
          .duplicateCheckRun(token: token)
          .listen(_onProgress, onError: _onError, onDone: _onDone);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _error = '$error';
      });
    }
  }

  void _onProgress(DuplicateCheckProgress progress) {
    if (!mounted) return;
    setState(() {
      switch (progress.stage) {
        case 'progress':
          _current = progress.current.toInt();
          _total = progress.total.toInt();
          _currentFile = progress.message;
        case 'warning':
          _warnings.add(progress.message);
        case 'group':
          if (progress.group case final group?) _groups.add(group);
        case 'done':
          _current = progress.current.toInt();
          _total = progress.total.toInt();
          _running = false;
          _done = true;
          _currentFile = '';
        case 'cancelled':
          _running = false;
          _done = true;
          _cancelRequested = true;
          _currentFile = '';
      }
    });
  }

  void _onError(Object error, StackTrace stackTrace) {
    final token = _token;
    _token = null;
    if (token != null) unawaited(rust.duplicateCheckCancel(token: token));
    if (!mounted) return;
    setState(() {
      _running = false;
      _done = true;
      _error = '$error';
    });
  }

  void _onDone() {
    _token = null;
    if (!mounted || !_running) return;
    setState(() {
      _running = false;
      _done = true;
      _currentFile = '';
    });
  }

  Future<void> _cancel() async {
    final token = _token;
    if (token == null || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    await rust.duplicateCheckCancel(token: token);
  }

  @override
  void dispose() {
    final token = _token;
    if (token != null) unawaited(rust.duplicateCheckCancel(token: token));
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

class _DuplicateGroupTile extends StatelessWidget {
  const _DuplicateGroupTile({required this.index, required this.group});

  final int index;
  final DuplicateCandidateGroup group;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text('候选组 ${index + 1} · ${group.items.length} 个文件'),
    subtitle: Text(_formatBytes(group.fileSize.toInt())),
    children: [
      for (final item in group.items)
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16),
          leading: Icon(_sourceIcon(item.sourceType)),
          title: Text(item.fileName),
          subtitle: Text(
            '${item.animeTitle}${item.episodeNo == null ? '' : ' · 第 ${item.episodeNo} 集'}\n'
            '${_sourceLabel(item.sourceType)} · ${item.filePath}',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
        ),
    ],
  );
}

IconData _sourceIcon(String sourceType) => switch (sourceType) {
  'smb' => Icons.dns_outlined,
  'webdav' => Icons.cloud_outlined,
  _ => Icons.folder_outlined,
};

String _sourceLabel(String sourceType) => switch (sourceType) {
  'smb' => 'SMB',
  'webdav' => 'WebDAV',
  'saf' => 'Android 文件夹',
  _ => '本地',
};

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}
