import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';

class PlayerPage extends StatefulWidget {
  /// The full playlist and the index to start at, so 上/下集 and autoplay work.
  final List<Episode> episodes;
  final int initialIndex;

  const PlayerPage({
    super.key,
    required this.episodes,
    required this.initialIndex,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  // Enable libass so ASS/SSA + embedded subtitles render with their styling via
  // mpv. On Android libass REQUIRES a bundled font (asset + its internal name),
  // otherwise NO subtitle renders at all.
  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      libass: true,
      libassAndroidFont: 'assets/fonts/LXGWWenKaiGBScreen.ttf',
      libassAndroidFontName: 'LXGW WenKai GB Screen',
    ),
  );
  late final VideoController _controller = VideoController(_player);

  late int _index = widget.initialIndex;
  Episode get _ep => widget.episodes[_index];

  Timer? _saveTimer;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _resumed = false;
  bool _tracksHandled = false;
  double _rate = 1.0;
  double _subDelay = 0; // seconds
  StreamSubscription? _completedSub;
  // Open SAF file descriptor for the current episode (Android); released when
  // switching episodes or closing so the fd doesn't leak.
  PlayableHandle? _handle;

  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  // On phones the player takes over the whole screen in landscape — there's no
  // windowed/fullscreen split, so the back button exits straight to the detail
  // page in one press.
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _openCurrent();
    _listen();
  }

  Future<void> _openCurrent() async {
    _resumed = false;
    _tracksHandled = false;
    _subDelay = 0;
    // Release the previous episode's SAF fd (if any) before opening the next.
    await _handle?.release();
    try {
      _handle = await MediaSource.forEpisode(_ep).resolvePlayable(_ep);
      await _player.open(Media(_handle!.uri));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开视频: $e')),
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _listen() {
    _player.stream.position.listen((pos) {
      _positionMs = pos.inMilliseconds;
      if (!_resumed &&
          _durationMs > 0 &&
          _ep.lastPositionMs.toInt() > 3000 &&
          !_ep.watched) {
        _resumed = true;
        _player.seek(Duration(milliseconds: _ep.lastPositionMs.toInt()));
      }
    });
    _player.stream.duration.listen((d) => _durationMs = d.inMilliseconds);
    _player.stream.tracks.listen((tracks) {
      if (_tracksHandled) return;
      if (tracks.subtitle.isEmpty && tracks.audio.isEmpty) return;
      _tracksHandled = true;
      _applyTrackPreference(tracks);
    });
    // Autoplay the next episode when one finishes.
    _completedSub = _player.stream.completed.listen((done) {
      if (done && _durationMs > 0) _playNext(auto: true);
    });
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
  }

  // ---- Track preference (per anime, remembered) ----

  String get _subPrefKey => 'sub_pref_${_ep.animeId}';
  String get _audioPrefKey => 'audio_pref_${_ep.animeId}';

  Future<void> _applyTrackPreference(Tracks tracks) async {
    final prefs = await SharedPreferences.getInstance();
    final savedSub = prefs.getString(_subPrefKey);
    final savedAudio = prefs.getString(_audioPrefKey);

    final subs =
        tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (subs.isNotEmpty) {
      // Prefer a remembered manual choice (matched by title), else language.
      SubtitleTrack? pick;
      if (savedSub != null) {
        for (final t in subs) {
          if ((t.title ?? t.language ?? t.id) == savedSub) {
            pick = t;
            break;
          }
        }
      }
      pick ??= (subs..sort((a, b) => _langScore(b.language, b.title)
          .compareTo(_langScore(a.language, a.title)))).first;
      _player.setSubtitleTrack(pick);
    }

    final audios =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (audios.isNotEmpty) {
      AudioTrack? pick;
      if (savedAudio != null) {
        for (final t in audios) {
          if ((t.title ?? t.language ?? t.id) == savedAudio) {
            pick = t;
            break;
          }
        }
      }
      pick ??= (audios..sort((a, b) => _langScore(b.language, b.title)
          .compareTo(_langScore(a.language, a.title)))).first;
      _player.setAudioTrack(pick);
    }
  }

  Future<void> _rememberSub(SubtitleTrack t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subPrefKey, t.title ?? t.language ?? t.id);
  }

  Future<void> _rememberAudio(AudioTrack t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioPrefKey, t.title ?? t.language ?? t.id);
  }

  int _langScore(String? language, String? title) {
    final meta = '${language ?? ''} ${title ?? ''}'.toLowerCase();
    final isChinese = meta.contains('zh') ||
        meta.contains('chi') ||
        meta.contains('chs') ||
        meta.contains('cht') ||
        meta.contains('中') ||
        meta.contains('简') ||
        meta.contains('繁') ||
        meta.contains('汉') ||
        meta.contains('漢');
    if (!isChinese) return 0;
    if (meta.contains('简') ||
        meta.contains('chs') ||
        meta.contains('hans') ||
        meta.contains('sc')) {
      return 3;
    }
    return 2;
  }

  Future<void> _save() async {
    if (_durationMs <= 0) return;
    try {
      await rust.updateProgress(
        episodeId: _ep.id,
        positionMs: _positionMs,
        durationMs: _durationMs,
      );
    } catch (_) {}
  }

  // ---- Playlist navigation ----

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.episodes.length - 1;

  Future<void> _playPrev() async {
    if (!_hasPrev) return;
    await _save();
    setState(() => _index--);
    await _openCurrent();
  }

  Future<void> _playNext({bool auto = false}) async {
    if (!_hasNext) {
      if (auto && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已经是最后一集了')),
        );
      }
      return;
    }
    await _save();
    setState(() => _index++);
    await _openCurrent();
  }

  Future<void> _setRate(double rate) async {
    await _player.setRate(rate);
    if (mounted) setState(() => _rate = rate);
  }

  Future<void> _setSubDelay(double seconds) async {
    _subDelay = seconds;
    // mpv property: positive delay shows subtitles later.
    await (_player.platform as dynamic)?.setProperty('sub-delay', '$seconds');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _completedSub?.cancel();
    _save();
    _player.dispose();
    _handle?.release();
    // Restore portrait orientation + system UI when leaving the player.
    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Desktop (mouse/keyboard) and mobile (touch) need different control sets:
    // MaterialDesktopVideoControls has hover seek bar + keyboard shortcuts;
    // MaterialVideoControls has the touch gestures (double-tap seek, swipe
    // volume/brightness, long-press speed). Pick per platform so PC keeps a
    // full, usable control bar.
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    final video = Video(
      controller: _controller,
      controls: isDesktop
          ? MaterialDesktopVideoControls
          : MaterialVideoControls,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        // libass draws subtitles onto the video texture; hide the Flutter
        // overlay to avoid double text.
        visible: false,
      ),
    );

    final Widget themed = isDesktop
        ? MaterialDesktopVideoControlsTheme(
            normal: _desktopTheme(),
            fullscreen: _desktopTheme(),
            child: video,
          )
        : MaterialVideoControlsTheme(
            normal: _mobileTheme(),
            fullscreen: _mobileTheme(),
            child: video,
          );

    return Scaffold(backgroundColor: Colors.black, body: themed);
  }

  // ---- Desktop controls (mouse + keyboard) ----

  MaterialDesktopVideoControlsThemeData _desktopTheme() {
    return MaterialDesktopVideoControlsThemeData(
      // Top bar: back + title + rate + tracks + subtitle-delay.
      topButtonBar: [
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _popSelf,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _ep.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        _desktopRateButton(),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles_outlined),
          onPressed: _showTrackSheet,
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.more_time_outlined),
          onPressed: _showSubDelaySheet,
        ),
      ],
      // Bottom bar mirrors the media_kit default, plus our prev/next hooks.
      bottomButtonBar: [
        MaterialDesktopCustomButton(
          icon: Icon(Icons.skip_previous,
              color: _hasPrev ? Colors.white : Colors.white30),
          onPressed: _hasPrev ? _playPrev : () {},
        ),
        const MaterialDesktopPlayOrPauseButton(),
        MaterialDesktopCustomButton(
          icon: Icon(Icons.skip_next,
              color: _hasNext ? Colors.white : Colors.white30),
          onPressed: _hasNext ? () => _playNext() : () {},
        ),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ],
    );
  }

  Widget _desktopRateButton() => MaterialDesktopCustomButton(
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 20),
            Text('${_rate}x', style: const TextStyle(fontSize: 11)),
          ],
        ),
        onPressed: _showRateSheet,
      );

  // ---- Mobile controls (touch gestures) ----

  MaterialVideoControlsThemeData _mobileTheme() {
    return MaterialVideoControlsThemeData(
      // Touch gestures.
      seekOnDoubleTap: true,
      volumeGesture: true,
      brightnessGesture: true,
      seekGesture: true,
      speedUpOnLongPress: true,
      speedUpFactor: 2.0,
      seekOnDoubleTapBackwardDuration: const Duration(seconds: 10),
      seekOnDoubleTapForwardDuration: const Duration(seconds: 10),
      // Top bar: back + title + rate + tracks + subtitle-delay.
      topButtonBar: [
        MaterialCustomButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _popSelf,
        ),
        Expanded(
          child: Text(
            _ep.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        _rateButton(),
        MaterialCustomButton(
          icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
          onPressed: _showTrackSheet,
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.more_time_outlined, color: Colors.white),
          onPressed: _showSubDelaySheet,
        ),
      ],
      // Bottom primary bar: prev / play-pause / next around the seek bar.
      primaryButtonBar: [
        MaterialCustomButton(
          icon: Icon(Icons.skip_previous,
              color: _hasPrev ? Colors.white : Colors.white30),
          onPressed: _hasPrev ? _playPrev : () {},
        ),
        const SizedBox(width: 8),
        const MaterialPlayOrPauseButton(iconSize: 48),
        const SizedBox(width: 8),
        MaterialCustomButton(
          icon: Icon(Icons.skip_next,
              color: _hasNext ? Colors.white : Colors.white30),
          onPressed: _hasNext ? () => _playNext() : () {},
        ),
      ],
      // Bottom bar: position only — no fullscreen button, since the mobile
      // player is already fullscreen+landscape (avoids a redundant nested
      // fullscreen route and the double-back it caused).
      bottomButtonBar: const [
        MaterialPositionIndicator(),
        Spacer(),
      ],
    );
  }

  void _popSelf() {
    if (mounted) Navigator.of(context).maybePop();
  }

  Widget _rateButton() {
    return MaterialCustomButton(
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, color: Colors.white, size: 20),
          Text('${_rate}x',
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
      onPressed: _showRateSheet,
    );
  }

  void _showRateSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final s in _speeds)
              ListTile(
                dense: true,
                leading: s == _rate
                    ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                    : const SizedBox(width: 24),
                title: Text('${s}x',
                    style: const TextStyle(color: Colors.white)),
                onTap: () {
                  _setRate(s);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSubDelaySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('字幕延迟：${_subDelay.toStringAsFixed(1)} 秒',
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
                const SizedBox(height: 4),
                const Text('正值让字幕更晚出现，负值更早',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _delayBtn('-1s', () async {
                      await _setSubDelay(_subDelay - 1);
                      setSheet(() {});
                    }),
                    _delayBtn('-0.5s', () async {
                      await _setSubDelay(_subDelay - 0.5);
                      setSheet(() {});
                    }),
                    _delayBtn('归零', () async {
                      await _setSubDelay(0);
                      setSheet(() {});
                    }),
                    _delayBtn('+0.5s', () async {
                      await _setSubDelay(_subDelay + 0.5);
                      setSheet(() {});
                    }),
                    _delayBtn('+1s', () async {
                      await _setSubDelay(_subDelay + 1);
                      setSheet(() {});
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _delayBtn(String label, VoidCallback onTap) =>
      OutlinedButton(onPressed: onTap, child: Text(label));

  void _showTrackSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      showDragHandle: true,
      builder: (context) {
        final tracks = _player.state.tracks;
        final current = _player.state.track;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _trackHeader(Icons.subtitles, '字幕'),
                _trackTile('关闭字幕', current.subtitle == SubtitleTrack.no(), () {
                  _player.setSubtitleTrack(SubtitleTrack.no());
                }),
                for (final t in tracks.subtitle)
                  if (t.id != 'auto' && t.id != 'no')
                    _trackTile(
                      _trackLabel(t.title, t.language, t.id),
                      current.subtitle.id == t.id,
                      () {
                        _player.setSubtitleTrack(t);
                        _rememberSub(t);
                      },
                    ),
                const Divider(color: Colors.white24, height: 1),
                _trackHeader(Icons.audiotrack, '音轨'),
                for (final t in tracks.audio)
                  if (t.id != 'auto' && t.id != 'no')
                    _trackTile(
                      _trackLabel(t.title, t.language, t.id),
                      current.audio.id == t.id,
                      () {
                        _player.setAudioTrack(t);
                        _rememberAudio(t);
                      },
                    ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _trackHeader(IconData icon, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Colors.white70),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white70, fontWeight: FontWeight.bold)),
          ],
        ),
      );

  Widget _trackTile(String label, bool selected, VoidCallback onTap) => ListTile(
        dense: true,
        title: Text(label, style: const TextStyle(color: Colors.white)),
        trailing: selected
            ? const Icon(Icons.check, color: Colors.lightBlueAccent)
            : null,
        onTap: () {
          onTap();
          Navigator.pop(context);
        },
      );

  String _trackLabel(String? title, String? language, String id) {
    final parts = <String>[];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (language != null && language.isNotEmpty && language != title) {
      parts.add(language);
    }
    if (parts.isEmpty) return '轨道 $id';
    return parts.join(' · ');
  }
}
