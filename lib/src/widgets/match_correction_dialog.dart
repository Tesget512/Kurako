import 'package:flutter/material.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import 'cover_image.dart';

class MatchCorrectionDialog extends StatefulWidget {
  final int animeId;
  final String initialKeyword;

  const MatchCorrectionDialog({
    super.key,
    required this.animeId,
    required this.initialKeyword,
  });

  @override
  State<MatchCorrectionDialog> createState() => _MatchCorrectionDialogState();
}

class _MatchCorrectionDialogState extends State<MatchCorrectionDialog> {
  late final TextEditingController _controller;
  List<BangumiSubject> _results = [];
  bool _loading = false;
  bool _binding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialKeyword);
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await rust.searchBangumi(keyword: _controller.text.trim());
      if (mounted) setState(() => _results = res);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bind(BangumiSubject subject) async {
    setState(() => _binding = true);
    try {
      await rust.bindAnime(animeId: widget.animeId, bangumiId: subject.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _binding = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('绑定失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 560,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '手动匹配 Bangumi',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        labelText: '搜索关键词',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('搜索'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('搜索失败: $_error'));
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有结果，试试其他关键词'));
    }
    return Stack(
      children: [
        ListView.separated(
          itemCount: _results.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final s = _results[i];
            final title = s.nameCn.isNotEmpty ? s.nameCn : s.name;
            return ListTile(
              leading: SizedBox(
                width: 44,
                height: 60,
                child: CoverImage(url: s.coverUrl),
              ),
              title: Text(title),
              subtitle: Text(
                [if (s.airDate != null) s.airDate!, s.name].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _binding ? null : () => _bind(s),
            );
          },
        ),
        if (_binding)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
