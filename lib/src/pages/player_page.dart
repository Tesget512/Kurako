import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_pip_mode/simple_pip.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../state/providers.dart';

/// A video chapter marker parsed from mpv's `chapter-list`.
class _Chapter {
  final String title;
  final double timeSec;
  const _Chapter(this.title, this.timeSec);
}

class PlayerPage extends ConsumerStatefulWidget {
  /// The full playlist and the index to start at, so 上/下集 and autoplay work.
  final List<Episode> episodes;
  final int initialIndex;

  const PlayerPage({
    super.key,
    required this.episodes,
    required this.initialIndex,
  });

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
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
  // Decoder mode is read once at construction (VideoControllerConfiguration is
  // fixed for the controller's lifetime; changing it re-enters the player).
  late final VideoController _controller = VideoController(
    _player,
    configuration: _decodeConfig(),
  );

  static VideoControllerConfiguration _decodeConfig() {
    // Read the persisted decode mode synchronously from the cached prefs value
    // set at startup; default 'auto' keeps media_kit's platform defaults.
    switch (decodeModeStartupValue) {
      case 'hw':
        return const VideoControllerConfiguration(
            enableHardwareAcceleration: true, hwdec: 'auto');
      case 'sw':
        return const VideoControllerConfiguration(
            enableHardwareAcceleration: false, hwdec: 'no');
      default:
        return const VideoControllerConfiguration();
    }
  }

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
  // External subtitle files next to the video (auto-loaded; listed in the
  // track sheet so the user can switch between them).
  List<SubtitleCandidate> _extSubs = const [];
  // The uri of the currently-active external subtitle, if any.
  String? _activeExtSub;
  // Chapters parsed from mpv's chapter-list after open (empty = none).
  List<_Chapter> _chapters = const [];
  // Active dark color scheme for the player UI (seeded from the app theme).
  // Set at the top of build(); all controls/sheets read from it for MD3 color.
  late ColorScheme _cs = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6750A4), brightness: Brightness.dark);
  // Open SAF file descriptor for the current episode (Android); released when
  // switching episodes or closing so the fd doesn't leak.
  PlayableHandle? _handle;

  // Quick-seek jump (seconds), read from [seekDurationProvider] each build.
  int _seekSec = 10;

  // Android picture-in-picture entry point. enterPipMode() works through the
  // plugin's method channel with a plain FlutterActivity; the enter/exit
  // callbacks (which would need a native Activity wrapper) are intentionally
  // not used — media_kit's controls auto-hide and PiP has no touch focus, so
  // the small window stays clean on its own.
  SimplePip? _pip;

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
    // Android-only native picture-in-picture (button-triggered).
    if (Platform.isAndroid) {
      _pip = SimplePip();
    }
    _openCurrent();
    _listen();
  }

  Future<void> _enterPip() async {
    if (!Platform.isAndroid) return;
    try {
      await _pip?.enterPipMode();
    } catch (_) {
      // Device without PiP support; ignore.
    }
  }

  Future<void> _openCurrent() async {
    _resumed = false;
    _tracksHandled = false;
    _subDelay = 0;
    _extSubs = const [];
    _activeExtSub = null;
    _chapters = const [];
    // Release the previous episode's SAF fd (if any) before opening the next.
    await _handle?.release();
    try {
      _handle = await MediaSource.forEpisode(_ep).resolvePlayable(_ep);
      await _player.open(Media(_handle!.uri));
      _loadExternalSubtitles();
      _loadChapters();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开视频: $e')),
        );
      }
    }
    if (mounted) setState(() {});
  }

  /// Find sidecar subtitle files (video.sc.ass etc.) and auto-load the best
  /// one. mpv can't discover them itself for SMB (http proxy URL) or SAF
  /// (fd://) sources, and even locally auto-load needs matching filenames only.
  Future<void> _loadExternalSubtitles() async {
    List<SubtitleCandidate> subs;
    try {
      subs = await MediaSource.forEpisode(_ep).listSubtitles(_ep);
    } catch (_) {
      return;
    }
    if (!mounted || subs.isEmpty) return;
    setState(() => _extSubs = subs);
    // Prefer simplified Chinese variants (sc/chs/simplified), then any.
    SubtitleCandidate best = subs.first;
    var bestScore = -1;
    for (final s in subs) {
      final n = s.fileName.toLowerCase();
      var score = 0;
      if (n.contains('sc') || n.contains('chs') || n.contains('简')) score = 2;
      if (n.contains('tc') || n.contains('cht') || n.contains('繁')) score = 1;
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    await _loadExtSub(best);
  }

  Future<void> _loadExtSub(SubtitleCandidate sub) async {
    try {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(sub.uri, title: sub.fileName),
      );
      if (mounted) setState(() => _activeExtSub = sub.uri);
    } catch (_) {}
  }

  /// Read embedded chapter markers via mpv (media_kit has no chapters state).
  Future<void> _loadChapters() async {
    // chapter-list only fills once the file is loaded; wait for a duration.
    try {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return;
    }
    try {
      final raw = await (_player.platform as dynamic)
          ?.getProperty('chapter-list') as String?;
      if (raw == null || raw.isEmpty || !mounted) return;
      final list = jsonDecode(raw) as List<dynamic>;
      final chapters = <_Chapter>[];
      for (var i = 0; i < list.length; i++) {
        final m = list[i] as Map<String, dynamic>;
        final t = (m['time'] as num?)?.toDouble() ?? 0;
        final title = (m['title'] as String?)?.trim() ?? '';
        chapters.add(_Chapter(title.isEmpty ? '章节 ${i + 1}' : title, t));
      }
      if (mounted && chapters.isNotEmpty) {
        setState(() => _chapters = chapters);
      }
    } catch (_) {
      // No chapters or malformed JSON — the button just stays hidden.
    }
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
    // Skip embedded-subtitle auto-pick when an external sidecar file already
    // loaded — external subs usually exist because the embedded ones don't fit.
    if (subs.isNotEmpty && _activeExtSub == null) {
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

  // Jump forward by the configured quick-seek duration.
  Future<void> _quickSeekForward() async {
    final target = Duration(milliseconds: _positionMs) +
        Duration(seconds: _seekSec);
    final max = Duration(milliseconds: _durationMs);
    await _player.seek(_durationMs > 0 && target > max ? max : target);
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
    // Live values from providers: quick-seek duration (also feeds double-tap).
    _seekSec = ref.watch(seekDurationProvider);
    // The player lives over a black video surface, so its UI is always dark —
    // seed a dark MD3 scheme from the active theme color so controls, the seek
    // bar and bottom sheets are all on-brand regardless of app light/dark mode.
    final seed = ref.watch(themeProvider).seedColor;
    _cs = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);

    // Desktop (mouse/keyboard) and mobile (touch) need different control sets:
    // MaterialDesktopVideoControls has hover seek bar + keyboard shortcuts;
    // MaterialVideoControls has the touch gestures (double-tap seek, swipe
    // volume/brightness, long-press speed). Touch-mode lets touchscreen
    // desktop devices opt into the touch controls too.
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final touchMode = ref.watch(touchModePlayerProvider);
    final useTouchControls = !isDesktop || touchMode;

    final video = Video(
      controller: _controller,
      controls:
          useTouchControls ? MaterialVideoControls : MaterialDesktopVideoControls,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        // libass draws subtitles onto the video texture; hide the Flutter
        // overlay to avoid double text.
        visible: false,
      ),
    );

    final Widget themed = useTouchControls
        ? MaterialVideoControlsTheme(
            normal: _mobileTheme(),
            fullscreen: _mobileTheme(),
            child: video,
          )
        : MaterialDesktopVideoControlsTheme(
            normal: _desktopTheme(),
            fullscreen: _desktopTheme(),
            child: video,
          );

    // media_kit's long-press speed-up only registers onLongPress/onLongPressEnd
    // — if the system interrupts the gesture (navigation gesture, PiP, an
    // incoming call), the cancel path fires instead of onLongPressEnd and the
    // rate stays stuck at speedUpFactor. Watch raw pointer up/cancel and
    // restore the user's chosen rate shortly after every release.
    final Widget guarded = useTouchControls
        ? Listener(
            behavior: HitTestBehavior.translucent,
            onPointerUp: (_) => _restoreRateAfterGesture(),
            onPointerCancel: (_) => _restoreRateAfterGesture(),
            child: themed,
          )
        : themed;

    final dark = Theme.of(context).copyWith(colorScheme: _cs);

    return Theme(
      data: dark,
      // media_kit's controls-theme updateShouldNotify is broken (inverted), so
      // a mounted controls tree never sees a new themeData. Key the subtree on
      // the values baked into the theme (seek duration, control set) to force
      // a clean remount whenever they change — double-tap durations included.
      child: KeyedSubtree(
        key: ValueKey('player-controls-$_seekSec-$useTouchControls'),
        child: Scaffold(backgroundColor: Colors.black, body: guarded),
      ),
    );
  }

  /// After any touch release/cancel, make sure the playback rate matches the
  /// user's selection — repairs media_kit's missing long-press cancel handling.
  void _restoreRateAfterGesture() {
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if ((_player.state.rate - _rate).abs() > 0.01) {
        _player.setRate(_rate);
      }
    });
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
        // Quick-seek: click jumps forward; right-click or long-press opens the
        // duration setting (desktop has no double-tap-hold convention).
        Tooltip(
          message: '快进 ${_seekSec}s（右键调节时长）',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _quickSeekForward,
            onLongPress: _showSeekDurationSheet,
            onSecondaryTap: _showSeekDurationSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fast_forward,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 2),
                  Consumer(
                    builder: (context, ref, _) {
                      final s = ref.watch(seekDurationProvider);
                      return Text('${s}s',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles_outlined),
          onPressed: _showTrackSheet,
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.more_time_outlined),
          onPressed: _showSubDelaySheet,
        ),
        if (_chapters.isNotEmpty)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: _showChapterSheet,
          ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.info_outline),
          onPressed: _showInfoSheet,
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
      seekOnDoubleTapBackwardDuration: Duration(seconds: _seekSec),
      seekOnDoubleTapForwardDuration: Duration(seconds: _seekSec),
      // MD3 seek bar: theme-colored, thicker, bigger thumb. Lifted fully above
      // the bottom button row (bottom:56 > buttonBarHeight) — same layout as
      // the desktop controls — so it can't be mis-tapped at the screen edge.
      seekBarThumbColor: _cs.primary,
      seekBarColor: Colors.white24,
      seekBarPositionColor: _cs.primary,
      seekBarBufferColor: Colors.white38,
      seekBarHeight: 4.2,
      seekBarThumbSize: 13,
      seekBarMargin: const EdgeInsets.only(left: 16, right: 16, bottom: 56),
      bottomButtonBarMargin:
          const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      // Top bar: back + title + quick-seek + rate + tracks + subtitle-delay.
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
        _seekButton(),
        if (Platform.isAndroid)
          MaterialCustomButton(
            icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
            onPressed: _enterPip,
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
        if (_chapters.isNotEmpty)
          MaterialCustomButton(
            icon: const Icon(Icons.bookmarks_outlined, color: Colors.white),
            onPressed: _showChapterSheet,
          ),
        MaterialCustomButton(
          icon: const Icon(Icons.info_outline, color: Colors.white),
          onPressed: _showInfoSheet,
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

  // Quick-seek button: tap jumps forward by the configured duration; long-press
  // opens the duration setting. The label watches the provider directly via
  // Consumer — media_kit's controls theme has a broken updateShouldNotify, so
  // the button bar isn't rebuilt when we hand it a fresh theme; watching here
  // keeps the shown duration live regardless.
  Widget _seekButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _quickSeekForward,
      onLongPress: _showSeekDurationSheet,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fast_forward, color: Colors.white, size: 20),
            const SizedBox(width: 2),
            Consumer(
              builder: (context, ref, _) {
                final s = ref.watch(seekDurationProvider);
                return Text('${s}s',
                    style: const TextStyle(color: Colors.white, fontSize: 11));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSeekDurationSheet() {
    final cs = Theme.of(context).colorScheme;
    int local = _seekSec; // immediate feedback; provider write is async
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('快进 / 快退时长：$local 秒',
                    style: TextStyle(color: cs.onSurface, fontSize: 16)),
                const SizedBox(height: 4),
                Text('双击画面或点击顶部按钮时跳转的时长',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                Slider(
                  value: local.toDouble(),
                  min: 5,
                  max: 90,
                  divisions: 17, // steps of 5
                  label: '$local 秒',
                  onChanged: (v) {
                    local = v.round();
                    ref.read(seekDurationProvider.notifier).set(local);
                    setSheet(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRateSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      showDragHandle: true,
      builder: (context) => SafeArea(
        // Scrollable so all speeds stay reachable in landscape / short
        // viewports (a non-scrolling Wrap silently clipped the tail entries).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final s in _speeds)
                ListTile(
                  dense: true,
                  leading: s == _rate
                      ? Icon(Icons.check, color: cs.primary)
                      : const SizedBox(width: 24),
                  title: Text('${s}x', style: TextStyle(color: cs.onSurface)),
                  selected: s == _rate,
                  selectedTileColor: cs.secondaryContainer,
                  onTap: () {
                    _setRate(s);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSubDelaySheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
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
                    style: TextStyle(color: cs.onSurface, fontSize: 16)),
                const SizedBox(height: 4),
                Text('正值让字幕更晚出现，负值更早',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
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
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
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
                  _activeExtSub = null;
                  _player.setSubtitleTrack(SubtitleTrack.no());
                }),
                for (final t in tracks.subtitle)
                  if (t.id != 'auto' && t.id != 'no')
                    _trackTile(
                      _trackLabel(t.title, t.language, t.id),
                      _activeExtSub == null && current.subtitle.id == t.id,
                      () {
                        _activeExtSub = null;
                        _player.setSubtitleTrack(t);
                        _rememberSub(t);
                      },
                    ),
                if (_extSubs.isNotEmpty) ...[
                  _trackHeader(Icons.folder_open, '外部字幕'),
                  for (final s in _extSubs)
                    _trackTile(
                      s.fileName,
                      _activeExtSub == s.uri,
                      () => _loadExtSub(s),
                    ),
                ],
                ListTile(
                  dense: true,
                  leading: Icon(Icons.file_open_outlined,
                      color: cs.onSurfaceVariant),
                  title: Text('浏览字幕文件…',
                      style: TextStyle(color: cs.onSurface)),
                  onTap: () async {
                    Navigator.pop(context);
                    await _pickSubtitleFile();
                  },
                ),
                Divider(color: cs.outlineVariant, height: 1),
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

  /// Manual subtitle pick — any subtitle file on the device.
  Future<void> _pickSubtitleFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ass', 'srt', 'ssa', 'sub', 'vtt'],
      );
    } catch (_) {
      return;
    }
    final path = result?.files.single.path;
    if (path == null) return;
    final name = path.replaceAll('\\', '/').split('/').last;
    await _loadExtSub(SubtitleCandidate(fileName: name, uri: path));
  }

  // ---- Chapters ----

  String _fmtTime(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _showChapterSheet() {
    final cs = Theme.of(context).colorScheme;
    final posSec = _positionMs / 1000.0;
    // The chapter currently playing: last one whose start <= position.
    var currentIdx = -1;
    for (var i = 0; i < _chapters.length; i++) {
      if (_chapters[i].timeSec <= posSec + 0.5) currentIdx = i;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _trackHeader(Icons.bookmarks, '章节 / 书签'),
              for (var i = 0; i < _chapters.length; i++)
                ListTile(
                  dense: true,
                  leading: i == currentIdx
                      ? Icon(Icons.play_arrow, color: cs.primary)
                      : const SizedBox(width: 24),
                  title: Text(_chapters[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurface)),
                  trailing: Text(_fmtTime(_chapters[i].timeSec),
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12)),
                  selected: i == currentIdx,
                  selectedTileColor: cs.secondaryContainer,
                  onTap: () {
                    _player.seek(Duration(
                        milliseconds:
                            (_chapters[i].timeSec * 1000).round()));
                    Navigator.pop(context);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Playback info (video params / decoder / SMB transfer) ----

  void _showInfoSheet() {
    final cs = Theme.of(context).colorScheme;
    final isSmb = _handle != null && _ep.sourceType == 'smb';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      showDragHandle: true,
      builder: (context) => _PlaybackInfoSheet(
        player: _player,
        episode: _ep,
        smbActive: isSmb && _handle!.uri.startsWith('http://127.0.0.1'),
      ),
    );
  }

  Widget _trackHeader(IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color: cs.onSurfaceVariant, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _trackTile(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      title: Text(label, style: TextStyle(color: cs.onSurface)),
      selected: selected,
      selectedTileColor: cs.secondaryContainer,
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () {
        onTap();
        Navigator.pop(context);
      },
    );
  }

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

/// Live playback-info panel: video/audio parameters, decoder state, and — for
/// SMB streams — proxy transfer speed. Refreshes once a second while open.
class _PlaybackInfoSheet extends StatefulWidget {
  final Player player;
  final Episode episode;
  final bool smbActive;
  const _PlaybackInfoSheet({
    required this.player,
    required this.episode,
    required this.smbActive,
  });

  @override
  State<_PlaybackInfoSheet> createState() => _PlaybackInfoSheetState();
}

class _PlaybackInfoSheetState extends State<_PlaybackInfoSheet> {
  Timer? _timer;
  String _hwdec = '…';
  // SMB proxy counters: previous sample and derived speed.
  BigInt? _lastBytes;
  double _speedBps = 0;
  BigInt _totalBytes = BigInt.zero;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final hw = await (widget.player.platform as dynamic)
          ?.getProperty('hwdec-current') as String?;
      if (hw != null && hw.isNotEmpty) _hwdec = hw;
    } catch (_) {}
    if (widget.smbActive) {
      try {
        final bytes = await rust.smbProxyStats();
        if (_lastBytes != null) {
          _speedBps = (bytes - _lastBytes!).toDouble();
        }
        _lastBytes = bytes;
        _totalBytes = bytes;
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _fmtBytes(double b) {
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
    return '${b.toStringAsFixed(0)} B/s';
  }

  String _fmtTotal(BigInt b) {
    final mb = b.toDouble() / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vp = widget.player.state.videoParams;
    final ap = widget.player.state.audioParams;
    final tracks = widget.player.state.track;
    final videoCodec = widget.player.state.tracks.video
        .where((t) => t.id == tracks.video.id)
        .map((t) => t.codec)
        .firstOrNull;
    final audioBitrate = widget.player.state.audioBitrate;

    final hwActive = vp.hwPixelformat != null && vp.hwPixelformat!.isNotEmpty;
    final rows = <(String, String)>[
      if (vp.w != null && vp.h != null) ('分辨率', '${vp.w} × ${vp.h}'),
      if (videoCodec != null && videoCodec.isNotEmpty) ('视频编码', videoCodec),
      ('解码方式', _hwdec == 'no' || _hwdec == ''
          ? '软件解码'
          : '硬件解码（$_hwdec）'),
      if (vp.pixelformat != null) ('像素格式', vp.pixelformat!),
      if (hwActive) ('硬解像素格式', vp.hwPixelformat!),
      if (vp.aspect != null) ('宽高比', vp.aspect!.toStringAsFixed(3)),
      if (vp.colormatrix != null) ('色彩矩阵', vp.colormatrix!),
      if (vp.primaries != null) ('色域', vp.primaries!),
      if (vp.gamma != null) ('传递函数', vp.gamma!),
      if (ap.format != null) ('音频格式', ap.format!),
      if (ap.sampleRate != null) ('采样率', '${ap.sampleRate} Hz'),
      if (ap.channels != null) ('声道', ap.channels!),
      if (audioBitrate != null && audioBitrate > 0)
        ('音频码率', '${(audioBitrate / 1000).round()} kbps'),
      if (widget.smbActive) ...[
        ('SMB 传输速度', _fmtBytes(_speedBps)),
        ('SMB 累计流量', _fmtTotal(_totalBytes)),
      ],
    ];

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text('播放信息',
                      style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(label,
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 13)),
                      ),
                      Expanded(
                        child: Text(value,
                            style:
                                TextStyle(color: cs.onSurface, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
