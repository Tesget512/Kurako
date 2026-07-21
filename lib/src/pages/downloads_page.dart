import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';

/// Management page for SMB files downloaded to local storage. Deleting an
/// entry removes both the record and the file; playback then goes back to
/// streaming over the network.
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  late Future<List<DownloadEntry>> _future = rust.listDownloads();

  void _reload() {
    setState(() => _future = rust.listDownloads());
  }

  String _fmtSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _fileName(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  Future<void> _delete(DownloadEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地副本'),
        content: Text(
            '删除「${_fileName(entry.localPath)}」的本地文件？\n之后播放该视频将恢复走 SMB 网络。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await rust.removeDownload(id: entry.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除本地副本')),
        );
      }
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载管理')),
      body: FutureBuilder<List<DownloadEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('加载失败: ${snapshot.error}'));
          }
          final entries = snapshot.data ?? const [];
          if (entries.isEmpty) {
            return const Center(child: Text('还没有下载到本地的视频'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return ListTile(
                leading: const Icon(Icons.video_file_outlined),
                title: Text(
                  _fileName(e.localPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_fmtSize(e.bytesTotal.toInt())} · ${e.localPath}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '删除本地副本',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(e),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
