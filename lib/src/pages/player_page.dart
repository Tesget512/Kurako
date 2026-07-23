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
import 'package:window_manager/window_manager.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../state/providers.dart';
import '../widgets/window_caption.dart';

/// A video chapter marker parsed from mpv's `chapter-list`.
class _Chapter {
  final String title;
  final double timeSec;
  const _Chapter(this.title, this.timeSec);
}

/// Which panel the right-side drawer shows. All the player's secondary menus
/// (previously bottom sheets / a broken popup) share one endDrawer.
enum _Panel { menu, episodes, tracks, rate, seek, subDelay, info, chapters }

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
  // Monotonic open counter. Each _openCurrent() call takes the next value;
  // after an await it checks it's still the newest, so rapid episode switches
  // (especially SMB, which registers a proxy token + opens a stream) don't race
  // two overlapping opens into a deadlock.
  int _openSeq = 0;
  // Debounce for rapid episode switching (next/prev/list-tap) over SMB — same
  // logic on every platform. Fixes "快速连续切集，视频几秒加载不出来": a burst
  // of N taps used to hammer N SMB file opens at the NAS at once (Windows via
  // the redirector, Android via our loopback proxy), which throttles the
  // surplus so the final episode only loads once the stale connections are
  // reaped (a few seconds). Now the index/highlight update instantly but the
  // actual open waits until the user settles, so a burst collapses to a single
  // open of the last target. Local/SAF sources skip this (no NAS to throttle).
  Timer? _switchDebounce;
  // Scaffold key so the control bars can open the right-side episode drawer.
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  // Which panel the endDrawer currently shows.
  _Panel _drawerPanel = _Panel.episodes;
  // Uniform row height for the episode picker (set as the ListView's
  // itemExtent) so the current episode's scroll offset is a simple
  // multiplication — no post-frame layout query needed.
  static const double _episodeTileHeight = 72;
  // Recreated each time the episode panel opens (see [_openPanel]) so it
  // starts scrolled to the currently-playing episode instead of always at the
  // top — the drawer used to reset to the first episode on every open.
  ScrollController? _episodeScrollController;

  // Desktop native fullscreen state (window_manager.setFullScreen). We DON'T
  // use media_kit's own fullscreen: it pushes a fresh Video on the root
  // Navigator, orphaning this Scaffold + its endDrawer, so the control buttons
  // (which open our drawer) silently no-op until you leave fullscreen. Toggling
  // the OS window instead keeps the single Scaffold hosting the Video, so every
  // button and the drawer keep working. A ValueNotifier (not setState) drives
  // the button icon because the controls subtree is keyed and won't rebuild on
  // a plain setState.
  final ValueNotifier<bool> _fullscreen = ValueNotifier<bool>(false);

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

  /// Toggle native OS fullscreen (desktop only). No-op on real mobile, which is
  /// already fullscreen+landscape.
  Future<void> _toggleFullscreen() async {
    if (_isMobile) return;
    final next = !_fullscreen.value;
    try {
      await windowManager.setFullScreen(next);
      _fullscreen.value = next;
    } catch (_) {}
  }

  Future<void> _enterPip() async {
    if (!Platform.isAndroid) return;
    try {
      await _pip?.enterPipMode();
    } catch (_) {
      // Device without PiP support; ignore.
    }
  }

  // Bounded retry for a stuck/occupied open (e.g. a file another player just
  // released is still momentarily locked — commonly hit switching from the
  // external player back to this one for the same episode). media_kit's
  // `open()` doesn't throw for a file that never actually loads — it just sits
  // spinning — so success is confirmed by watching for a real duration within
  // [_openWatchdog]; a timeout retries after [_openRetryGap], up to
  // [_maxOpenAttempts], then reports a real error instead of spinning forever.
  static const int _maxOpenAttempts = 3;
  static const Duration _openWatchdog = Duration(seconds: 7);
  static const Duration _openRetryGap = Duration(seconds: 3);

  Future<void> _openCurrent() async {
    final seq = ++_openSeq;
    _resumed = false;
    _tracksHandled = false;
    _subDelay = 0;
    _extSubs = const [];
    _activeExtSub = null;
    _chapters = const [];
    // Release the previous episode's handle (SAF fd / SMB proxy token) BEFORE
    // resolving the next, so a rapid switch doesn't leave two SMB streams (and
    // proxy connections) contending on the small Rust runtime.
    final old = _handle;
    _handle = null;
    await old?.release();
    // A newer open superseded us while releasing — abandon this one.
    if (seq != _openSeq) return;

    for (var attempt = 1; attempt <= _maxOpenAttempts; attempt++) {
      try {
        final handle = await MediaSource.forEpisode(_ep).resolvePlayable(_ep);
        if (seq != _openSeq) {
          // Superseded during resolve — release what we just acquired and bail.
          await handle.release();
          return;
        }
        _handle = handle;
        await _player.open(Media(handle.uri));
        if (seq != _openSeq) return;
        final loaded = await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(_openWatchdog)
            .then((_) => true)
            .catchError((_) => false);
        if (seq != _openSeq) return;
        if (loaded) {
          _loadExternalSubtitles(seq);
          _loadChapters(seq);
          break;
        }
        await _handle?.release();
        _handle = null;
        if (attempt == _maxOpenAttempts) {
          if (mounted && seq == _openSeq) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('视频加载超时，可能被其他播放器占用，请稍后重试')),
            );
          }
          break;
        }
        await Future.delayed(_openRetryGap);
        if (seq != _openSeq) return;
      } catch (e) {
        if (attempt == _maxOpenAttempts) {
          if (mounted && seq == _openSeq) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('无法打开视频: $e')),
            );
          }
          break;
        }
        await Future.delayed(_openRetryGap);
        if (seq != _openSeq) return;
      }
    }
    if (mounted && seq == _openSeq) setState(() {});
  }

  /// Find sidecar subtitle files (video.sc.ass etc.) and auto-load the best
  /// one. mpv can't discover them itself for SMB (http proxy URL) or SAF
  /// (fd://) sources, and even locally auto-load needs matching filenames only.
  Future<void> _loadExternalSubtitles(int seq) async {
    List<SubtitleCandidate> subs;
    try {
      subs = await MediaSource.forEpisode(_ep).listSubtitles(_ep);
    } catch (_) {
      return;
    }
    if (!mounted || subs.isEmpty || seq != _openSeq) return;
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
  Future<void> _loadChapters(int seq) async {
    // chapter-list only fills once the file is loaded; wait for a duration.
    try {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return;
    }
    if (seq != _openSeq) return;
    try {
      final raw = await (_player.platform as dynamic)
          ?.getProperty('chapter-list') as String?;
      if (raw == null || raw.isEmpty || !mounted || seq != _openSeq) return;
      final list = jsonDecode(raw) as List<dynamic>;
      final chapters = <_Chapter>[];
      for (var i = 0; i < list.length; i++) {
        final m = list[i] as Map<String, dynamic>;
        final t = (m['time'] as num?)?.toDouble() ?? 0;
        final title = (m['title'] as String?)?.trim() ?? '';
        chapters.add(_Chapter(title.isEmpty ? '章节 ${i + 1}' : title, t));
      }
      if (mounted && chapters.isNotEmpty && seq == _openSeq) {
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

  /// Open the currently-selected episode. Local/SAF sources open immediately;
  /// SMB sources debounce (same on every platform) so a burst of rapid switches
  /// only opens the final target, avoiding the SMB connection pile-up the NAS
  /// throttles. See [_switchDebounce].
  void _scheduleOpen() {
    if (_ep.sourceType != 'smb') {
      _openCurrent();
      return;
    }
    _switchDebounce?.cancel();
    _switchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _openCurrent();
    });
  }

  Future<void> _playPrev() async {
    if (!_hasPrev) return;
    await _save();
    setState(() => _index--);
    _scheduleOpen();
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
    _scheduleOpen();
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
    _switchDebounce?.cancel();
    _completedSub?.cancel();
    _episodeScrollController?.dispose();
    _save();
    _player.dispose();
    _handle?.release();
    // Restore portrait orientation + system UI when leaving the player.
    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else if (_fullscreen.value) {
      // Leave the OS window as we found it (windowed) when closing the player.
      windowManager.setFullScreen(false);
    }
    _fullscreen.dispose();
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
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: Colors.black,
          endDrawer: _buildDrawer(),
          // Open only via the buttons — an edge-swipe would fight the player's
          // horizontal seek gesture.
          endDrawerEnableOpenDragGesture: false,
          body: guarded,
        ),
      ),
    );
  }

  /// Show [panel] in the right-side drawer. All secondary menus route here so
  /// they render inside the Scaffold (fixing the popup that didn't work over
  /// media_kit's control layer).
  void _openPanel(_Panel panel) {
    if (panel == _Panel.episodes) {
      // A small look-ahead so the selected row isn't pinned to the very top
      // edge; the ListView clamps this to a valid offset once it lays out.
      final target = (_index - 1) * _episodeTileHeight;
      _episodeScrollController = ScrollController(
        initialScrollOffset: target < 0 ? 0 : target,
      );
    }
    setState(() => _drawerPanel = panel);
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// The right-side drawer, showing whichever panel [_drawerPanel] selects.
  Widget _buildDrawer() {
    final cs = _cs;
    final (IconData icon, String title, Widget body) = switch (_drawerPanel) {
      _Panel.menu => (Icons.tune, '播放器选项', _menuPanel()),
      _Panel.episodes => (Icons.playlist_play, '选集', _episodePanel()),
      _Panel.tracks => (Icons.subtitles, '字幕 / 音轨', _tracksPanel()),
      _Panel.rate => (Icons.speed, '播放速度', _ratePanel()),
      _Panel.seek => (Icons.fast_forward, '快进时长', _seekPanel()),
      _Panel.subDelay => (Icons.more_time, '字幕延迟', _subDelayPanel()),
      _Panel.info => (Icons.info_outline, '播放信息', _infoPanel()),
      _Panel.chapters => (Icons.bookmarks, '章节', _chaptersPanel()),
    };
    return Drawer(
      backgroundColor: cs.surface,
      width: 340,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Solid title bar so scrolled-up list items (with a highlighted
            // background) don't show through / cover the title.
            Material(
              color: cs.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    Icon(icon, color: cs.onSurface),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // Body on its own Material so it clips under the title bar.
            Expanded(child: Material(color: cs.surface, child: body)),
          ],
        ),
      ),
    );
  }

  /// Menu panel: a compact list routing to the other panels — the mobile "更多"
  /// entry, so the top bar stays uncluttered.
  Widget _menuPanel() {
    final cs = _cs;
    Widget tile(IconData icon, String label, _Panel panel) => ListTile(
          leading: Icon(icon, color: cs.onSurfaceVariant),
          title: Text(label, style: TextStyle(color: cs.onSurface)),
          onTap: () => setState(() => _drawerPanel = panel),
        );
    return ListView(
      children: [
        tile(Icons.subtitles_outlined, '字幕 / 音轨', _Panel.tracks),
        tile(Icons.more_time_outlined, '字幕延迟', _Panel.subDelay),
        tile(Icons.info_outline, '播放信息', _Panel.info),
        if (_chapters.isNotEmpty)
          tile(Icons.bookmarks_outlined, '章节', _Panel.chapters),
      ],
    );
  }

  /// Episode picker panel: jump to any episode (save + reopen).
  Widget _episodePanel() {
    final cs = _cs;
    return ListView.builder(
      controller: _episodeScrollController,
      itemExtent: _episodeTileHeight,
      itemCount: widget.episodes.length,
      itemBuilder: (context, i) {
        final ep = widget.episodes[i];
        final selected = i == _index;
        return ListTile(
          dense: true,
          leading: selected
              ? Icon(Icons.play_arrow, color: cs.primary)
              : CircleAvatar(
                  radius: 12,
                  backgroundColor: cs.surfaceContainerHighest,
                  child: Text('${ep.episodeNo?.toInt() ?? i + 1}',
                      style: TextStyle(fontSize: 11, color: cs.onSurface)),
                ),
          title: Text(ep.fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface)),
          selected: selected,
          selectedTileColor: cs.secondaryContainer,
          onTap: () async {
            Navigator.of(context).pop();
            if (i == _index) return;
            await _save();
            setState(() => _index = i);
            _scheduleOpen();
          },
        );
      },
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
      // Hide the mouse cursor when the controls auto-hide (idle over the video).
      hideMouseOnControlsRemoval: true,
      // Disable media_kit's own fullscreen (a root-navigator route push that
      // orphans this Scaffold's endDrawer). We drive the OS window instead.
      toggleFullscreenOnDoublePress: false,
      // Replace the default shortcut map so keyF/escape use our native toggle;
      // keep the usual space/arrow/mute bindings wired to the player directly.
      keyboardShortcuts: {
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _player.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.mediaPlay): () =>
            _player.play(),
        const SingleActivator(LogicalKeyboardKey.mediaPause): () =>
            _player.pause(),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
            _player.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _player.seek(
            Duration(milliseconds: _positionMs) - const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _player.seek(
            Duration(milliseconds: _positionMs) + const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _player
            .setVolume((_player.state.volume + 5).clamp(0.0, 100.0)),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _player
            .setVolume((_player.state.volume - 5).clamp(0.0, 100.0)),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            _player.setVolume(_player.state.volume > 0 ? 0 : 100),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen.value) _toggleFullscreen();
        },
      },
      // Top bar: back + title + secondary-menu buttons (each opens the right
      // drawer) + window buttons. Playback controls live below the seek bar.
      topButtonBar: [
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _popSelf,
        ),
        const SizedBox(width: 8),
        // Dragging the title moves the frameless window (double-click to
        // maximize) — otherwise there's no way to reposition it while the
        // player fills the route. No-op on mobile.
        Expanded(
          child: WindowDragArea(
            child: Text(
              _ep.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles_outlined),
          onPressed: () => _openPanel(_Panel.tracks),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.more_time_outlined),
          onPressed: () => _openPanel(_Panel.subDelay),
        ),
        if (_chapters.isNotEmpty)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: () => _openPanel(_Panel.chapters),
          ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () => _openPanel(_Panel.info),
        ),
        if (widget.episodes.length > 1)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.playlist_play),
            onPressed: () => _openPanel(_Panel.episodes),
          ),
        if (!_isMobile) const WindowButtons(light: true),
      ],
      // Under the seek bar: pure playback controls — prev/play/next, rate,
      // quick-seek, volume, position, fullscreen.
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
        _desktopRateButton(),
        // Quick-seek: click jumps; right-click / long-press sets the duration.
        Tooltip(
          message: '快进 ${_seekSec}s（右键调节时长）',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _quickSeekForward,
            onLongPress: () => _openPanel(_Panel.seek),
            onSecondaryTap: () => _openPanel(_Panel.seek),
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
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11));
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        _desktopFullscreenButton(),
      ],
    );
  }

  /// Native-fullscreen toggle button; the icon tracks [_fullscreen] via a
  /// ValueListenableBuilder since the keyed controls subtree won't rebuild on a
  /// plain setState when fullscreen flips.
  Widget _desktopFullscreenButton() => ValueListenableBuilder<bool>(
        valueListenable: _fullscreen,
        builder: (context, fs, _) => MaterialDesktopCustomButton(
          icon: Icon(fs ? Icons.fullscreen_exit : Icons.fullscreen),
          onPressed: _toggleFullscreen,
        ),
      );

  Widget _desktopRateButton() => MaterialDesktopCustomButton(
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 20),
            Text('${_rate}x', style: const TextStyle(fontSize: 11)),
          ],
        ),
        onPressed: () => _openPanel(_Panel.rate),
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
      // Tame the drag sensitivity — the package defaults (vertical 100,
      // horizontal 1000) move brightness/volume/seek far too much per drag.
      // Higher = less sensitive.
      verticalGestureSensitivity: 400,
      horizontalGestureSensitivity: 3000,
      // Double-tap seek stays at the fixed 10s convention; the customizable
      // duration ([seekDurationProvider]) drives only the top-bar quick-seek
      // button so the two gestures are independent.
      seekOnDoubleTapBackwardDuration: const Duration(seconds: 10),
      seekOnDoubleTapForwardDuration: const Duration(seconds: 10),
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
      // Top bar: back + title + quick-seek + rate + episode drawer + overflow.
      topButtonBar: [
        MaterialCustomButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _popSelf,
        ),
        // WindowDragArea is a no-op on real mobile; on a touchscreen Windows
        // device with 触屏模式 enabled it lets the title drag-move the window.
        Expanded(
          child: WindowDragArea(
            child: Text(
              _ep.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
        _seekButton(),
        if (Platform.isAndroid)
          MaterialCustomButton(
            icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
            onPressed: _enterPip,
          ),
        _rateButton(),
        if (widget.episodes.length > 1)
          MaterialCustomButton(
            icon: const Icon(Icons.playlist_play, color: Colors.white),
            onPressed: () => _openPanel(_Panel.episodes),
          ),
        MaterialCustomButton(
          icon: const Icon(Icons.tune, color: Colors.white),
          onPressed: () => _openPanel(_Panel.menu),
        ),
        // On a real phone/tablet this is a no-op; on Windows with 触屏模式
        // (touch controls opted-in on a touchscreen desktop) the window still
        // needs its minimize/maximize/close buttons somewhere.
        if (!_isMobile) const WindowButtons(light: true),
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
      // Bottom bar: position + (on Windows 触屏模式 only) a native-fullscreen
      // toggle. Real mobile is already fullscreen+landscape, so the button is
      // omitted there (guarded by !_isMobile) to avoid a redundant control.
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        if (!_isMobile) _touchFullscreenButton(),
      ],
    );
  }

  /// Windows-touch fullscreen toggle; icon tracks [_fullscreen] live.
  Widget _touchFullscreenButton() => ValueListenableBuilder<bool>(
        valueListenable: _fullscreen,
        builder: (context, fs, _) => MaterialCustomButton(
          icon: Icon(fs ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white),
          onPressed: _toggleFullscreen,
        ),
      );

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
      onPressed: () => _openPanel(_Panel.rate),
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
      onLongPress: () => _openPanel(_Panel.seek),
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

  Widget _seekPanel() {
    final cs = _cs;
    int local = _seekSec;
    return StatefulBuilder(
      builder: (context, setPanel) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('快进 / 快退时长：$local 秒',
                style: TextStyle(color: cs.onSurface, fontSize: 16)),
            const SizedBox(height: 4),
            Text('点击顶部快进按钮时跳转的时长（双击画面固定 10 秒）',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            Slider(
              value: local.toDouble(),
              min: 5,
              max: 90,
              divisions: 17,
              label: '$local 秒',
              onChanged: (v) {
                local = v.round();
                ref.read(seekDurationProvider.notifier).set(local);
                setPanel(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _ratePanel() {
    final cs = _cs;
    return ListView(
      children: [
        for (final s in _speeds)
          ListTile(
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
    );
  }

  /// Subtitle-delay panel (drawer). Uses a StatefulBuilder for the local live
  /// value; writes go straight to mpv.
  Widget _subDelayPanel() {
    final cs = _cs;
    return StatefulBuilder(
      builder: (context, setPanel) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('字幕延迟：${_subDelay.toStringAsFixed(1)} 秒',
                style: TextStyle(color: cs.onSurface, fontSize: 16)),
            const SizedBox(height: 4),
            Text('正值让字幕更晚出现，负值更早',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 8,
              runSpacing: 8,
              children: [
                _delayBtn('-1s', () async {
                  await _setSubDelay(_subDelay - 1);
                  setPanel(() {});
                }),
                _delayBtn('-0.5s', () async {
                  await _setSubDelay(_subDelay - 0.5);
                  setPanel(() {});
                }),
                _delayBtn('归零', () async {
                  await _setSubDelay(0);
                  setPanel(() {});
                }),
                _delayBtn('+0.5s', () async {
                  await _setSubDelay(_subDelay + 0.5);
                  setPanel(() {});
                }),
                _delayBtn('+1s', () async {
                  await _setSubDelay(_subDelay + 1);
                  setPanel(() {});
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _delayBtn(String label, VoidCallback onTap) =>
      OutlinedButton(onPressed: onTap, child: Text(label));

  Widget _tracksPanel() {
    final cs = _cs;
    final tracks = _player.state.tracks;
    final current = _player.state.track;
    // External subtitle files (loaded via mpv sub-add) also surface in
    // tracks.subtitle with their filename as the title — skip those in the
    // embedded list so each file shows once (in the 外部字幕 section below).
    final extNames = _extSubs.map((s) => s.fileName).toSet();
    final embeddedSubs = tracks.subtitle
        .where((t) =>
            t.id != 'auto' &&
            t.id != 'no' &&
            !(t.title != null && extNames.contains(t.title)))
        .toList();
    // Audio can arrive with duplicate entries over the SMB proxy — dedup by a
    // composite key, and add an index when several share one label.
    final audios =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final seenAudio = <String>{};
    final uniqueAudio = <AudioTrack>[];
    for (final t in audios) {
      final key = '${t.id}|${t.title}|${t.language}|${t.codec}';
      if (seenAudio.add(key)) uniqueAudio.add(t);
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _trackHeader(Icons.subtitles, '字幕'),
          _trackTile('关闭字幕', current.subtitle == SubtitleTrack.no(), () {
            _activeExtSub = null;
            _player.setSubtitleTrack(SubtitleTrack.no());
          }),
          for (final t in embeddedSubs)
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
            leading: Icon(Icons.file_open_outlined, color: cs.onSurfaceVariant),
            title: Text('浏览字幕文件…', style: TextStyle(color: cs.onSurface)),
            onTap: () async {
              Navigator.pop(context);
              await _pickSubtitleFile();
            },
          ),
          Divider(color: cs.outlineVariant, height: 1),
          _trackHeader(Icons.audiotrack, '音轨'),
          for (var i = 0; i < uniqueAudio.length; i++)
            _trackTile(
              _audioLabel(uniqueAudio, i),
              current.audio.id == uniqueAudio[i].id,
              () {
                _player.setAudioTrack(uniqueAudio[i]);
                _rememberAudio(uniqueAudio[i]);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Audio track label; appends " · N" when several tracks share the same base
  /// label so identical-language tracks stay distinguishable.
  String _audioLabel(List<AudioTrack> audios, int i) {
    final t = audios[i];
    final base = _trackLabel(t.title, t.language, t.id);
    final sameLabel =
        audios.where((o) => _trackLabel(o.title, o.language, o.id) == base);
    if (sameLabel.length <= 1) return base;
    final ordinal = audios.take(i + 1).where((o) =>
        _trackLabel(o.title, o.language, o.id) == base).length;
    return '$base · $ordinal';
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

  Widget _chaptersPanel() {
    final cs = _cs;
    final posSec = _positionMs / 1000.0;
    var currentIdx = -1;
    for (var i = 0; i < _chapters.length; i++) {
      if (_chapters[i].timeSec <= posSec + 0.5) currentIdx = i;
    }
    return ListView.builder(
      itemCount: _chapters.length,
      itemBuilder: (context, i) => ListTile(
        dense: true,
        leading: i == currentIdx
            ? Icon(Icons.play_arrow, color: cs.primary)
            : const SizedBox(width: 24),
        title: Text(_chapters[i].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface)),
        trailing: Text(_fmtTime(_chapters[i].timeSec),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        selected: i == currentIdx,
        selectedTileColor: cs.secondaryContainer,
        onTap: () {
          _player.seek(
              Duration(milliseconds: (_chapters[i].timeSec * 1000).round()));
          Navigator.pop(context);
        },
      ),
    );
  }

  // Episode picker moved to the right-side endDrawer (_episodeDrawer); opened
  // via the playlist button / overflow menu.

  // ---- Playback info (video params / decoder / SMB transfer) ----

  Widget _infoPanel() {
    final isSmb = _handle != null && _ep.sourceType == 'smb';
    return _PlaybackInfoSheet(
      player: _player,
      episode: _ep,
      smbActive: isSmb && _handle!.uri.startsWith('http://127.0.0.1'),
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
  // Audio bitrate fallback: state.audioBitrate is null for some containers
  // (e.g. FLAC/lossless in MKV); query mpv's audio-bitrate property instead.
  double? _audioBitrateProp;
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
    // Fallback bitrate when state.audioBitrate is unset for the container.
    try {
      final raw = await (widget.player.platform as dynamic)
          ?.getProperty('audio-bitrate') as String?;
      final v = raw == null ? null : double.tryParse(raw);
      if (v != null && v > 0) _audioBitrateProp = v;
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
    final audioBitrate = widget.player.state.audioBitrate ?? _audioBitrateProp;

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
