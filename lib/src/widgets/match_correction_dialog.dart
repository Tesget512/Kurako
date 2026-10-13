import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bangumi_mirror.dart';
import '../services/scan_coordinator.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import 'cover_image.dart';

class MatchCorrectionDialog extends ConsumerStatefulWidget {
  /// Re-match a whole anime entry: pass its id. Mutually exclusive with
  /// [episodeId].
  final int? animeId;

  /// Match a single video file into its own entry (split it out of a
  /// mis-grouped anime): pass the episode's id. Mutually exclusive with
  /// [animeId].
  final int? episodeId;
  final String initialKeyword;

  const MatchCorrectionDialog({
    super.key,
    this.animeId,
    this.episodeId,
    required this.initialKeyword,
  }) : assert(
         (animeId == null) != (episodeId == null),
         'exactly one of animeId / episodeId must be given',
       );

  @override
  ConsumerState<MatchCorrectionDialog> createState() =>
      _MatchCorrectionDialogState();
}

class _MatchCorrectionDialogState extends ConsumerState<MatchCorrectionDialog> {
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
      BangumiMirrorService.instance.reportApiFailure(e);
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bind(BangumiSubject subject) async {
    if (_binding) return;
    if (ref.read(scanCoordinatorProvider).running ||
        ref.read(libraryMutationBusyProvider)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('扫描或维护正在进行，请完成后再修改匹配')));
      return;
    }
    final reservation = ref.read(libraryMutationBusyProvider.notifier);
    reservation.state = true;
    setState(() => _binding = true);
    try {
      // Both paths resolve to the id of the anime the file/entry now belongs to
      // (a merge or a per-file split may not be the id we started from), so the
      // caller can navigate to whichever entry actually survived. The match is
      // persisted (sidecar next to the media, or the app fallback config) inside
      // these calls, so it survives a rescan — nothing more to do here.
      final int resultId;
      if (widget.episodeId != null) {
        resultId = (await rust.matchEpisode(
          episodeId: widget.episodeId!,
          bangumiId: subject.id,
        )).toInt();
      } else {
        resultId = (await rust.bindAnime(
          animeId: widget.animeId!,
          bangumiId: subject.id,
        )).toInt();
      }
      if (mounted) Navigator.of(context).pop(resultId);
    } catch (e) {
      BangumiMirrorService.instance.reportApiFailure(e);
      if (mounted) {
        setState(() => _binding = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('绑定失败: $e')));
      }
    } finally {
      reservation.state = false;
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
