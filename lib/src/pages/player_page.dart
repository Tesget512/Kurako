import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_pip_mode/simple_pip.dart';
import 'package:window_manager/window_manager.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/anime4k_shader_assets.dart';
import '../services/ios_platform.dart';
import '../services/media_source.dart';
import '../services/media_session.dart';
import '../services/playback_metadata.dart';
import '../services/playback_start.dart';
import '../state/providers.dart';
import '../state/player_appearance.dart';
import '../widgets/player_visuals.dart';
import '../widgets/window_caption.dart';

/// A video chapter marker parsed from mpv's `chapter-list`.
class _Chapter {
  final String title;
  final double timeSec;
  const _Chapter(this.title, this.timeSec);
}

/// Which panel the right-side drawer shows. All the player's secondary menus
/// (previously bottom sheets / a broken popup) share one endDrawer.
enum _Panel {
  menu,
  episodes,
  tracks,
  rate,
  seek,
  subDelay,
  superResolution,
  info,
  chapters,
}

class PlayerPage extends ConsumerStatefulWidget {
  /// The full playlist and the index to start at, so 上/下集 and autoplay work.
  final List<Episode> episodes;
  final int initialIndex;
  final String animeTitle;
  final String? coverUrl;

  const PlayerPage({
    super.key,
    required this.episodes,
    required this.initialIndex,
    this.animeTitle = 'Kurako',
    this.coverUrl,
  });

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> with WindowListener {
  // Enable libass so ASS/SSA + embedded subtitles render with their styling via
  // mpv. On Android libass REQUIRES a bundled font (asset + its internal name),
  // otherwise NO subtitle renders at all.
  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      libass: true,
      libassAndroidFont: 'assets/fonts/LXGWWenKaiGBScreen.ttf',
      libassAndroidFontName: 'LXGW WenKai GB Screen',
      // The player page surfaces warn/error lines through stream.log; the
      // default (error-only) hid file-open/demux failures during slow starts.
      logLevel: MPVLogLevel.warn,
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
    // set at startup. `enableHardwareAcceleration` controls media_kit_video's
    // output texture renderer; it is independent from libmpv's `hwdec` option.
    // Flutter 3.38+ can corrupt or crash the legacy Linux FlTextureGL path, so
    // Linux renders into a stable pixel-buffer texture. Automatic/hardware mode
    // still requests `auto-copy`, allowing VAAPI/VDPAU decoding while copying
    // decoded frames into that output buffer. Other platforms retain the
    // established media_kit GPU texture path.
    switch (decodeModeStartupValue) {
      case 'hw':
        return VideoControllerConfiguration(
          enableHardwareAcceleration: !Platform.isLinux,
          hwdec: Platform.isLinux ? 'auto-copy' : 'auto',
        );
      case 'sw':
        return const VideoControllerConfiguration(
          enableHardwareAcceleration: false,
          hwdec: 'no',
        );
      default:
        return Platform.isLinux
            ? const VideoControllerConfiguration(
                enableHardwareAcceleration: false,
                hwdec: 'auto-copy',
              )
            : const VideoControllerConfiguration();
    }
  }

  late int _index = widget.initialIndex;
  Episode get _ep => widget.episodes[_index];
  late final ValueNotifier<int> _episodeIndex;

  Timer? _saveTimer;
  bool _controlsLocked = false;
  bool _unlockControlVisible = false;
  Timer? _unlockControlTimer;
  bool _takingScreenshot = false;
  bool _playTogglePending = false;
  bool _completionHandled = false;
  bool _reportedSuperResolutionFailure = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _resumed = false;
  // Ignore events from the old media between an index change and the matching
  // player.open. Without this gate, the old stream can resume/complete using
  // the newly-selected episode's id during the SMB debounce window.
  bool _acceptPlaybackEvents = false;
  // media_kit first publishes placeholder `auto` / `no` tracks while a media
  // is opening. Embedded subtitle & audio preferences are therefore applied
  // independently, only after each real track list has arrived.
  bool _subtitlePreferenceApplied = false;
  bool _audioPreferenceApplied = false;
  double _rate = 1.0;
  double _subDelay = 0; // seconds
  StreamSubscription? _playingSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _tracksSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _logSub;
  StreamSubscription? _errorSub;
  // A demux/decode error that arrives mid-playback is reported once per open,
  // and only if playback does not recover on its own within the grace period.
  Timer? _runtimeErrorTimer;
  bool _runtimeErrorAlertShown = false;
  int _positionAtRuntimeError = 0;
  // External subtitle files next to the video (auto-loaded; listed in the
  // track sheet so the user can switch between them).
  List<SubtitleCandidate> _extSubs = const [];
  // The uri of the currently-active external subtitle, if any.
  String? _activeExtSub;
  PreparedSubtitle? _preparedExtSub;
  Directory? _subtitleCacheDirectory;
  // The subtitle panel is an endDrawer route and may stay mounted separately
  // from this page's normal rebuilds. Drive its checkmark with a notifier that
  // is updated once an explicit media_kit selection command has completed.
  // This represents embedded, external & disabled states without polling mpv.
  final ValueNotifier<SubtitleTrack> _selectedSubtitle =
      ValueNotifier<SubtitleTrack>(SubtitleTrack.auto());
  // Chapters parsed from mpv's chapter-list after open (empty = none).
  List<_Chapter> _chapters = const [];
  // Active dark color scheme for the player UI (seeded from the app theme).
  // Set at the top of build(); all controls/sheets read from it for MD3 color.
  late ColorScheme _cs = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );
  // Open SAF file descriptor for the current episode (Android); released when
  // switching episodes or closing so the fd doesn't leak.
  PlayableHandle? _handle;
  // Monotonic open counter. Each scheduled target takes the next value;
  // after an await it checks it's still the newest, so rapid episode switches
  // (especially SMB, which registers a proxy token + opens a stream) don't race
  // two overlapping opens into a deadlock.
  int _openSeq = 0;
  // Lets duration watchdogs finish immediately when a newer switch supersedes
  // them, instead of leaving each obsolete attempt alive for seven seconds.
  final ValueNotifier<int> _openGeneration = ValueNotifier<int>(0);
  // media_kit exposes async stop/open/dispose operations on one Player. Keep
  // them in a single pipeline so a superseded open can finish its cleanup
  // before the final debounced target starts touching the same mpv instance.
  Future<void> _playerLifecycle = Future<void>.value();
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

  // Quick-seek jump (seconds), kept in sync with [seekDurationProvider].
  int _seekSec = 10;
  String _superResolutionMode = 'off';
  ProviderSubscription<int>? _seekDurationSubscription;
  ProviderSubscription<ThemeSettings>? _themeSubscription;
  ProviderSubscription<Settings>? _settingsSubscription;

  // Android picture-in-picture entry point. enterPipMode() works through the
  // plugin's method channel with a plain FlutterActivity; the enter/exit
  // callbacks (which would need a native Activity wrapper) are intentionally
  // not used — media_kit's controls auto-hide and PiP has no touch focus, so
  // the small window stays clean on its own.
  SimplePip? _pip;
  bool _mediaSessionBound = false;
  bool? _autoPipConfigured;
  static const MethodChannel _androidChannel = MethodChannel(
    'kurako/android/network',
  );

  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  // On phones the player takes over the whole screen in landscape — there's no
  // windowed/fullscreen split, so the back button exits straight to the detail
  // page in one press.
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _episodeIndex = ValueNotifier<int>(_index);
    _seekSec = ref.read(seekDurationProvider);
    _superResolutionMode = ref.read(settingsProvider).superResolutionMode;
    _cs = ColorScheme.fromSeed(
      seedColor: ref.read(themeProvider).seedColor,
      brightness: Brightness.dark,
    );
    // Close these ourselves at the start of dispose. Riverpod 2.6.1 otherwise
    // closes Consumer dependencies after StatefulElement.unmount, leaving a
    // short window where an async preference load can rebuild a defunct page.
    _seekDurationSubscription = ref.listenManual<int>(seekDurationProvider, (
      _,
      next,
    ) {
      if (mounted && next != _seekSec) setState(() => _seekSec = next);
    });
    _themeSubscription = ref.listenManual<ThemeSettings>(themeProvider, (
      _,
      next,
    ) {
      if (!mounted) return;
      setState(() {
        _cs = ColorScheme.fromSeed(
          seedColor: next.seedColor,
          brightness: Brightness.dark,
        );
      });
    });
    _settingsSubscription = ref.listenManual<Settings>(settingsProvider, (
      previous,
      next,
    ) {
      if (mounted && next.superResolutionMode != _superResolutionMode) {
        setState(() => _superResolutionMode = next.superResolutionMode);
      }
      if (previous?.mediaSessionEnabled != next.mediaSessionEnabled ||
          previous?.backgroundPlayback != next.backgroundPlayback ||
          previous?.gestureSeekDurationSec != next.gestureSeekDurationSec) {
        unawaited(_syncMediaSession(next));
      }
      if (previous?.autoPictureInPicture != next.autoPictureInPicture) {
        unawaited(_configureAutoPip(next.autoPictureInPicture));
      }
    });
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
    if (!_isMobile) windowManager.addListener(this);
    _listen();
    // A back gesture or any other pop we did not initiate still has to restore
    // the system chrome, and it must happen while the route is animating out —
    // not in dispose(), which runs only after the previous route has laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      route?.animation?.addStatusListener(_onRouteStatus);
      _route = route;
    });
    unawaited(_initializePlayer());
  }

  ModalRoute<dynamic>? _route;

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) unawaited(_restoreSystemChrome());
  }

  Future<void> _initializePlayer() async {
    await ref.read(settingsProvider.notifier).ready;
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    if (settings.superResolutionMode != _superResolutionMode) {
      setState(() => _superResolutionMode = settings.superResolutionMode);
    }
    await _configureAutoPip(settings.autoPictureInPicture);
    if (!mounted) return;
    await _syncMediaSession(settings);
    if (mounted) _scheduleOpen(debounceRemote: false);
  }

  @override
  void onWindowBlur() {
    // A pointer released after Alt-Tab or outside the native window may not
    // deliver Flutter's pointer-up/cancel callback. Never leave the temporary
    // touch long-press speed active after the desktop window loses focus.
    if ((_player.state.rate - _rate).abs() > 0.01) {
      unawaited(_player.setRate(_rate));
    }
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

  Future<void> _configureAutoPip(bool enabled) async {
    if (!Platform.isAndroid) return;
    final active = enabled && _player.state.playing;
    if (_autoPipConfigured == active) return;
    _autoPipConfigured = active;
    try {
      await _androidChannel.invokeMethod<void>(
        'setAutoPictureInPicture',
        active,
      );
    } catch (_) {
      _autoPipConfigured = null;
    }
  }

  Future<void> _syncMediaSession(Settings settings) async {
    final handler = kurakoMediaSession;
    final enabled =
        _isMobile &&
        (settings.mediaSessionEnabled || settings.backgroundPlayback) &&
        handler != null;
    if (!enabled) {
      if (_mediaSessionBound && handler != null) {
        _mediaSessionBound = false;
        await handler.unbind(_player);
      }
      return;
    }
    _mediaSessionBound = true;
    try {
      await handler.bind(
        player: _player,
        episodes: widget.episodes,
        episodeIndex: _index,
        animeTitle: widget.animeTitle,
        coverUrl: widget.coverUrl,
        gestureSeekSeconds: settings.gestureSeekDurationSec,
        onPrevious: _playPrev,
        onNext: _playNext,
      );
    } catch (error, stackTrace) {
      _mediaSessionBound = false;
      debugPrint('Media session binding failed: $error\n$stackTrace');
    }
  }

  static const int _maxOpenAttempts = 2;
  static const Duration _openRetryGap = Duration(seconds: 2);

  Future<void> _openEpisode(int seq, Episode episode) async {
    if (!mounted || seq != _openSeq) return;
    // Debug-only stage timings: scheme + stage + elapsed only — never file
    // names, full URIs or proxy tokens, which can carry private paths.
    final openStopwatch = Stopwatch()..start();
    void trace(String stage) {
      if (!kDebugMode) return;
      final uriScheme = _handle?.uri.split(':').first;
      debugPrint(
        'kurako/open[$seq] +${openStopwatch.elapsedMilliseconds}ms $stage'
        '${uriScheme == null ? '' : ' via=$uriScheme'}',
      );
    }

    trace('start');
    _resumed = false;
    _subtitlePreferenceApplied = false;
    _audioPreferenceApplied = false;
    // sub-delay is a player-level mpv property that survives loadfile: reset
    // it in mpv too, not just the Dart field, or the previous episode's
    // adjustment silently keeps applying while the UI shows 0.
    if (_subDelay != 0) unawaited(_setSubDelay(0));
    _extSubs = const [];
    _activeExtSub = null;
    _selectedSubtitle.value = SubtitleTrack.auto();
    _chapters = const [];
    // Tell mpv to unload the URL before unregistering its proxy token. Releasing
    // first truncates the HTTP body while libavformat is still parsing it (the
    // EBML-header errors seen in the device log).
    final old = _handle;
    _handle = null;
    if (old != null || _preparedExtSub != null) {
      try {
        await _player.stop();
      } catch (_) {}
    }
    await _releaseActivePreparedSubtitle();
    await old?.release();
    if (seq != _openSeq) return;

    for (var attempt = 1; attempt <= _maxOpenAttempts; attempt++) {
      PlayableHandle? handle;
      try {
        // Capture [episode] when the generation is created. Reading the mutable
        // [_ep] after an await made an old task open the newly-selected episode
        // once, followed by the debounced task opening it a second time.
        handle = await MediaSource.forEpisode(episode).resolvePlayable(episode);
        if (seq != _openSeq) {
          // Superseded during resolve — release what we just acquired and bail.
          await handle.release();
          return;
        }
        _handle = handle;
        trace('resolved');
        final waiter = PlaybackStartWaiter(_player, _openGeneration, seq);
        PlaybackStartResult startResult;
        try {
          await _player.open(Media(handle.uri));
          trace('open returned');
          _acceptPlaybackEvents = mounted && seq == _openSeq;
          _durationMs = _player.state.duration.inMilliseconds;
          startResult = await waiter.wait(
            playbackStartTimeout(
              remote: handle.networkProxy || handle.uri.startsWith(r'\\'),
            ),
          );
          trace(startResult.name);
        } finally {
          await waiter.dispose();
        }
        if (seq != _openSeq || !mounted) {
          if (identical(_handle, handle)) _handle = null;
          try {
            await _player.stop();
          } catch (_) {}
          await handle.release();
          return;
        }
        if (startResult == PlaybackStartResult.ready) {
          // The video is playable the moment readiness fires; shaders,
          // sidecar subtitles and chapters only decorate it. Applying the
          // shader inline used to block them behind prefs load + shader
          // extraction + an mpv round-trip, stretching the perceived
          // startup for seconds. All three paths re-check [seq] internally,
          // so running them concurrently cannot leak into the next episode.
          if (mounted && seq == _openSeq) {
            unawaited(_applyConfiguredSuperResolution(seq));
            _loadExternalSubtitles(seq, episode);
            _loadChapters(seq);
          }
          break;
        }
        _acceptPlaybackEvents = false;
        try {
          await _player.stop();
        } catch (_) {}
        if (identical(_handle, handle)) _handle = null;
        await handle.release();
        if (startResult == PlaybackStartResult.failed &&
            attempt < _maxOpenAttempts) {
          await Future.delayed(_openRetryGap);
          if (seq != _openSeq) return;
          continue;
        }
        if (mounted && seq == _openSeq) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                startResult == PlaybackStartResult.failed
                    ? '视频加载失败，请检查媒体来源、网络或文件访问权限。'
                    : '视频加载超时，请检查媒体来源、网络或文件访问权限后重试。',
              ),
            ),
          );
        }
        break;
      } catch (e) {
        trace('failed ${e.runtimeType}');
        if (seq == _openSeq) {
          _acceptPlaybackEvents = false;
          try {
            await _player.stop();
          } catch (_) {}
        }
        // open() can throw after the handle (SAF fd / SMB proxy token) was
        // resolved and assigned — release it before the next attempt
        // overwrites _handle, or every failed attempt leaks one. Only if it
        // is still ours: a newer _openEpisode may have taken _handle over
        // (and already released this one) while we awaited.
        if (handle != null && identical(_handle, handle)) {
          _handle = null;
          await handle.release();
        }
        if (attempt == _maxOpenAttempts) {
          if (mounted && seq == _openSeq) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('无法打开视频，请检查媒体来源、网络或文件访问权限。')),
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

  /// Applies the persisted Anime4K choice after mpv has an attached video
  /// surface. A GLSL shader is a libmpv feature, so it deliberately lives at
  /// this layer rather than pretending to upscale a Flutter texture.
  Future<void> _applyConfiguredSuperResolution(int seq) async {
    // The player can open before Riverpod's SharedPreferences-backed settings
    // finish loading on a cold launch. Wait here (after the video is already
    // usable) so an enabled preference is never mistaken for the default off.
    await ref.read(settingsProvider.notifier).ready;
    if (seq != _openSeq) return;
    await _applySuperResolutionMode(
      ref.read(settingsProvider).superResolutionMode,
      seq: seq,
    );
  }

  Future<void> _applySuperResolutionMode(String mode, {int? seq}) async {
    try {
      if (seq != null && seq != _openSeq) return;
      final platform = _player.platform;
      if (platform is! NativePlayer) {
        throw StateError('当前播放器后端不支持 GLSL 着色器');
      }
      if (mode != 'off') {
        final directory = await Anime4kShaderAssets.ensureInstalled();
        if (seq != null && seq != _openSeq) return;
        final separator = Platform.isWindows ? ';' : ':';
        final shaders = switch (mode) {
          'anime4k-light' => Anime4kShaderAssets.lightShaderOrder,
          'anime4k-balanced' ||
          'anime4k-lite' => Anime4kShaderAssets.balancedShaderOrder,
          _ => const <String>[],
        };
        if (shaders.isEmpty) {
          await platform.command(['change-list', 'glsl-shaders', 'clr', '']);
          return;
        }
        final shaderPaths = shaders
            .map((name) => p.join(directory.path, name))
            .join(separator);
        await platform.command([
          'change-list',
          'glsl-shaders',
          'set',
          shaderPaths,
        ]);
      } else {
        await platform.command(['change-list', 'glsl-shaders', 'clr', '']);
      }
    } catch (error) {
      // Keep playback usable if a platform's libmpv build or its current GPU
      // renderer cannot compile GLSL. This covers renderers that use a
      // hardware overlay instead of an mpv GPU surface.
      if (mode != 'off' &&
          mounted &&
          (seq == null || seq == _openSeq) &&
          !_reportedSuperResolutionFailure) {
        _reportedSuperResolutionFailure = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Anime4K 超分辨率未启用：当前渲染器不支持 GLSL 着色器（$error）')),
        );
      }
    }
  }

  Future<void> _takeScreenshot() async {
    if (_takingScreenshot) return;
    setState(() => _takingScreenshot = true);
    try {
      final bytes = await _player.screenshot(
        format: 'image/png',
        includeLibassSubtitles: true,
      );
      if (bytes == null || bytes.isEmpty) {
        throw StateError('播放器没有返回可保存的画面');
      }
      final destination = Directory(
        effectiveDownloadDir(ref.read(downloadDirProvider)),
      );
      if (!await destination.exists()) {
        await destination.create(recursive: true);
      }
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File(p.join(destination.path, 'Kurako-$timestamp.png'));
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        if (Platform.isIOS) {
          var savedToPhotos = false;
          try {
            savedToPhotos = await IosPlatform.saveImageToPhotos(file.path);
          } catch (_) {
            // The private, Files-visible PNG remains available below when the
            // user denies Photos access or iOS rejects this particular frame.
          }
          if (!mounted) return;
          if (savedToPhotos) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('截图已保存到系统相册')));
            return;
          }
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('截图已保存到 ${file.path}')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('截图失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _takingScreenshot = false);
    }
  }

  /// Find sidecar subtitle files (video.sc.ass etc.) and auto-load the best
  /// one. mpv can't discover them itself for SMB (http proxy URL) or SAF
  /// (fd://) sources, and even locally auto-load needs matching filenames only.
  Future<void> _loadExternalSubtitles(int seq, Episode episode) async {
    List<SubtitleCandidate> subs;
    try {
      subs = await MediaSource.forEpisode(episode).listSubtitles(episode);
    } catch (_) {
      return;
    }
    if (!mounted || seq != _openSeq) {
      return;
    }
    if (subs.isEmpty) return;
    setState(() => _extSubs = subs);
    // Prefer whichever Chinese script (simplified/traditional) matches the
    // system language — see _scriptScore — falling back to the first entry if
    // nothing matches either dictionary so a differently-named file still loads.
    SubtitleCandidate best = subs.first;
    var bestScore = -1;
    for (final s in subs) {
      final score = _scriptScore(s.fileName.toLowerCase());
      if (score > bestScore) {
        bestScore = score;
        best = s;
      }
    }
    await _loadExtSub(best, notifyError: false);
  }

  Future<Directory> _subtitleCache() async {
    final existing = _subtitleCacheDirectory;
    if (existing != null) return existing;
    final root = await getTemporaryDirectory();
    final parent = Directory(p.join(root.path, 'kurako-subtitles'));
    await parent.create(recursive: true);
    unawaited(_removeStaleSubtitleCaches(parent));
    final directory = Directory(
      p.join(
        parent.path,
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}',
      ),
    );
    await directory.create(recursive: true);
    _subtitleCacheDirectory = directory;
    return directory;
  }

  Future<void> _removeStaleSubtitleCaches(Directory parent) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    try {
      await for (final entry in parent.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final modified = await entry.stat().then((stat) => stat.modified);
        if (modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  Future<void> _releasePreparedSubtitle(PreparedSubtitle? prepared) async {
    if (prepared == null) return;
    final proxyUrl = prepared.proxyUrl;
    if (proxyUrl != null) {
      try {
        await rust.releaseNetworkUrl(url: proxyUrl);
      } catch (_) {}
    }
    final temporaryPath = prepared.temporaryPath;
    if (temporaryPath != null) {
      try {
        final file = File(temporaryPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _releaseActivePreparedSubtitle() async {
    final prepared = _preparedExtSub;
    _preparedExtSub = null;
    await _releasePreparedSubtitle(prepared);
  }

  Future<void> _loadExtSub(
    SubtitleCandidate sub, {
    bool notifyError = true,
  }) async {
    final seq = _openSeq;
    PreparedSubtitle? prepared;
    final previousSource = _activeExtSub;
    final previousPrepared = _preparedExtSub;
    // Mark the external choice as pending before sub-add. That command itself
    // updates media_kit's track-list; without this guard the track-list listener
    // can mistake the newly-added sidecar for an embedded track and run the
    // automatic language picker against it a second time.
    _activeExtSub = sub.uri;
    try {
      final cache = await _subtitleCache();
      prepared = await rust.prepareSubtitle(
        sourceUri: sub.uri,
        fileName: sub.fileName,
        cacheDir: cache.path,
      );
      if (!mounted || seq != _openSeq) {
        await _releasePreparedSubtitle(prepared);
        return;
      }
      final track = SubtitleTrack.uri(prepared.uri, title: sub.fileName);
      await _player.setSubtitleTrack(track);
      if (!mounted || seq != _openSeq) {
        await _releasePreparedSubtitle(prepared);
        return;
      }
      _preparedExtSub = prepared;
      _selectedSubtitle.value = track;
      if (!identical(previousPrepared, prepared)) {
        await _releasePreparedSubtitle(previousPrepared);
      }
    } catch (error) {
      await _releasePreparedSubtitle(prepared);
      if (seq == _openSeq && _activeExtSub == sub.uri) {
        _activeExtSub = previousSource;
      }
      if (notifyError && mounted && seq == _openSeq) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法加载字幕：$error')));
      }
    }
  }

  /// Read embedded chapter markers via mpv (media_kit has no chapters state).
  Future<void> _loadChapters(int seq) async {
    // chapter-list only fills once the file is loaded; wait for a duration.
    if (!await _waitForLoadedDuration(const Duration(seconds: 15), seq: seq)) {
      return;
    }
    if (seq != _openSeq) return;
    try {
      final raw =
          await (_player.platform as dynamic)?.getProperty('chapter-list')
              as String?;
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

  /// Wait for media_kit to expose a real duration without losing an event from
  /// its broadcast stream. The state checks handle events published before the
  /// subscription; the second check closes the subscribe/check race itself.
  Future<bool> _waitForLoadedDuration(
    Duration timeout, {
    required int seq,
  }) async {
    bool isCurrent() => mounted && seq == _openSeq;
    if (!isCurrent()) return false;
    if (_player.state.duration > Duration.zero) return true;

    final result = Completer<bool>();
    void cancelIfSuperseded() {
      if (!isCurrent() && !result.isCompleted) result.complete(false);
    }

    _openGeneration.addListener(cancelIfSuperseded);
    final subscription = _player.stream.duration.listen((duration) {
      if (isCurrent() && duration > Duration.zero && !result.isCompleted) {
        result.complete(true);
      }
    });
    if (isCurrent() &&
        _player.state.duration > Duration.zero &&
        !result.isCompleted) {
      result.complete(true);
    }
    final timer = Timer(timeout, () {
      if (!result.isCompleted) {
        result.complete(isCurrent() && _player.state.duration > Duration.zero);
      }
    });
    try {
      return await result.future;
    } finally {
      timer.cancel();
      _openGeneration.removeListener(cancelIfSuperseded);
      await subscription.cancel();
    }
  }

  void _listen() {
    _playingSub = _player.stream.playing.listen((_) {
      if (Platform.isAndroid) {
        unawaited(
          _configureAutoPip(ref.read(settingsProvider).autoPictureInPicture),
        );
      }
    });
    _positionSub = _player.stream.position.listen((pos) {
      if (!mounted || !_acceptPlaybackEvents) return;
      _positionMs = pos.inMilliseconds;
      if (!_resumed &&
          ref.read(settingsProvider).autoResumePlayback &&
          _durationMs > 0 &&
          _ep.lastPositionMs.toInt() > 3000 &&
          !_ep.watched) {
        _resumed = true;
        _player.seek(Duration(milliseconds: _ep.lastPositionMs.toInt()));
      }
    });
    _durationSub = _player.stream.duration.listen((d) {
      if (mounted && _acceptPlaybackEvents) _durationMs = d.inMilliseconds;
    });
    _tracksSub = _player.stream.tracks.listen((tracks) {
      if (!mounted || !_acceptPlaybackEvents) return;
      final realSubtitles = tracks.subtitle.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final realAudio = tracks.audio.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final applySubtitles = realSubtitles && !_subtitlePreferenceApplied;
      final applyAudio = realAudio && !_audioPreferenceApplied;
      if (!applySubtitles && !applyAudio) return;
      if (applySubtitles) _subtitlePreferenceApplied = true;
      if (applyAudio) _audioPreferenceApplied = true;
      unawaited(
        _applyTrackPreference(
          tracks,
          applySubtitles: applySubtitles,
          applyAudio: applyAudio,
          seq: _openSeq,
        ),
      );
    });
    // Apply the current autoplay policy when one episode finishes.
    _completedSub = _player.stream.completed.listen((done) {
      if (_acceptPlaybackEvents && done && _durationMs > 0) {
        unawaited(_handlePlaybackCompleted());
      }
    });
    // mpv otherwise reports nothing when a local file never produces a
    // duration (file-not-found, demux hang...): the wait just times out with
    // no evidence. Surface warn/error log lines in Debug only; the text can
    // contain the media path, so print the prefix and level with a trimmed
    // reason instead of the full line.
    _logSub = _player.stream.log.listen((entry) {
      if (!kDebugMode || entry.level != 'warn' && entry.level != 'error') {
        return;
      }
      debugPrint(
        'kurako/mpv[${entry.level}] ${entry.prefix}: ${entry.text.split('\n').first}',
      );
    });
    // A damaged file on a healthy network fails *after* the start wait has
    // already succeeded: mpv reports an error and the UI otherwise keeps
    // showing a frozen frame or a spinner with no explanation. Report it once,
    // after a short grace period, unless playback moved on by itself.
    _errorSub = _player.stream.error.listen((message) {
      if (!mounted || !_acceptPlaybackEvents) return;
      if (_runtimeErrorAlertShown || _durationMs <= 0) return;
      _positionAtRuntimeError = _positionMs;
      _runtimeErrorTimer?.cancel();
      _runtimeErrorTimer = Timer(playbackErrorGrace, () {
        if (!mounted || !_acceptPlaybackEvents || _runtimeErrorAlertShown) {
          return;
        }
        // Any progress since the error means it was transient.
        if (_positionMs != _positionAtRuntimeError) return;
        _runtimeErrorAlertShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(playbackErrorNotice(message)),
            action: SnackBarAction(
              label: '重试',
              onPressed: () {
                if (mounted) _scheduleOpen(debounceRemote: false);
              },
            ),
          ),
        );
      });
    });
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
  }

  Future<void> _handlePlaybackCompleted() async {
    if (_completionHandled) return;
    _completionHandled = true;
    final autoPlayNext = ref.read(settingsProvider).autoPlayNext;
    if (autoPlayNext && _hasNext) {
      await _playNext(auto: true);
      return;
    }
    await _save();
    if (mounted) await _leavePlayer();
  }

  // ---- Track preference (per anime, remembered) ----

  String get _subPrefKey => 'sub_pref_${_ep.animeId}';
  String get _audioPrefKey => 'audio_pref_${_ep.animeId}';

  Future<void> _applyTrackPreference(
    Tracks tracks, {
    required bool applySubtitles,
    required bool applyAudio,
    required int seq,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || seq != _openSeq) return;
    final savedSub = prefs.getString(_subPrefKey);
    final savedAudio = prefs.getString(_audioPrefKey);

    final subs = tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    // Skip embedded-subtitle auto-pick when an external sidecar file already
    // loaded — external subs usually exist because the embedded ones don't fit.
    if (applySubtitles && subs.isNotEmpty && _activeExtSub == null) {
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
      pick ??=
          (subs..sort(
                (a, b) => _langScore(
                  b.language,
                  b.title,
                ).compareTo(_langScore(a.language, a.title)),
              ))
              .first;
      await _player.setSubtitleTrack(pick);
      if (!mounted || seq != _openSeq) return;
      // A sidecar subtitle may have finished loading while the embedded
      // command was in flight. In that case the sidecar is the newer explicit
      // choice and must keep ownership of the panel checkmark.
      if (_activeExtSub == null) _selectedSubtitle.value = pick;
    }

    final audios = tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (applyAudio && audios.isNotEmpty) {
      AudioTrack? pick;
      if (savedAudio != null) {
        for (final t in audios) {
          if ((t.title ?? t.language ?? t.id) == savedAudio) {
            pick = t;
            break;
          }
        }
      }
      pick ??=
          (audios..sort(
                (a, b) => _langScore(
                  b.language,
                  b.title,
                ).compareTo(_langScore(a.language, a.title)),
              ))
              .first;
      await _player.setAudioTrack(pick);
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
    final isChinese =
        meta.contains('zh') ||
        meta.contains('chi') ||
        meta.contains('中') ||
        meta.contains('汉') ||
        meta.contains('漢') ||
        _kSimplifiedMarkers.any(meta.contains) ||
        _kTraditionalMarkers.any(meta.contains);
    if (!isChinese) return 0;
    return 2 + _scriptScore(meta);
  }

  // Typical fansub filename/track-title markers for each Chinese script — a
  // small literal dictionary, not a language detector. "gb"/"big5" are the
  // legacy encoding names fansub groups still use as a stand-in for
  // simplified/traditional in release names; "simplified"/"traditional" spelled
  // out is how mpv/libass often labels a track derived from an ISO language tag
  // (e.g. "Chinese (Simplified) · chi") — neither word contains "sc"/"tc".
  static const _kSimplifiedMarkers = [
    'sc',
    'chs',
    'gb',
    'hans',
    'simplified',
    '简体',
    '简中',
    '简',
  ];
  static const _kTraditionalMarkers = [
    'tc',
    'cht',
    'big5',
    'hant',
    'traditional',
    '繁体',
    '繁中',
    '繁',
  ];

  /// Whether the OS is set to a Traditional-Chinese locale (script tag, or
  /// a region conventionally associated with Traditional — TW/HK/MO).
  /// Non-Chinese systems fall through to "prefer simplified" (the prior
  /// hardcoded default), same as a zh-CN/zh-SG system would.
  bool get _systemPrefersTraditional {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    if (locale.languageCode != 'zh') return false;
    switch (locale.scriptCode?.toLowerCase()) {
      case 'hant':
        return true;
      case 'hans':
        return false;
    }
    final region = locale.countryCode?.toUpperCase();
    return region == 'TW' || region == 'HK' || region == 'MO';
  }

  /// 2 = matches the system's preferred Chinese script, 1 = matches the other
  /// script, 0 = no script marker found at all in [textLower].
  int _scriptScore(String textLower) {
    final matchesSimplified = _kSimplifiedMarkers.any(textLower.contains);
    final matchesTraditional = _kTraditionalMarkers.any(textLower.contains);
    final preferTraditional = _systemPrefersTraditional;
    final preferredMatch = preferTraditional
        ? matchesTraditional
        : matchesSimplified;
    final otherMatch = preferTraditional
        ? matchesSimplified
        : matchesTraditional;
    if (preferredMatch) return 2;
    if (otherMatch) return 1;
    return 0;
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
  /// Remote sources debounce so a burst of rapid switches only opens the final
  /// target, avoiding needless connection and Range-probe pile-ups.
  void _scheduleOpen({bool debounceRemote = true}) {
    // The old video keeps playing (and emitting events) until the new open
    // lands — SMB debounce + retries + watchdog can stretch that to seconds.
    // Clear the progress snapshot NOW, synchronously with the index change,
    // so nothing pairs the new _ep.id with the old episode's numbers: the 5s
    // _save() tick would write the old position into the new episode (marking
    // it watched at an episode boundary), the resume listener would seek the
    // old video to the new episode's lastPosition, and the completed listener
    // would auto-advance a second time if the old episode finishes while the
    // switch is still pending.
    _positionMs = 0;
    _durationMs = 0;
    _resumed = false;
    _completionHandled = false;
    _acceptPlaybackEvents = false;
    _runtimeErrorTimer?.cancel();
    _runtimeErrorAlertShown = false;
    _switchDebounce?.cancel();
    final seq = ++_openSeq;
    _openGeneration.value = seq;
    final episode = _ep;
    final isRemote =
        episode.sourceType == 'smb' || episode.sourceType == 'webdav';
    if (!debounceRemote || !isRemote) {
      _enqueueOpen(seq, episode);
      return;
    }
    _switchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted && seq == _openSeq) {
        _enqueueOpen(seq, episode);
      }
    });
  }

  void _enqueueOpen(int seq, Episode episode) {
    final queued = _playerLifecycle.then((_) => _openEpisode(seq, episode));
    _playerLifecycle = queued.catchError((Object error, StackTrace stackTrace) {
      debugPrint('Player lifecycle operation failed: $error\n$stackTrace');
    });
  }

  void _selectEpisode(int index) {
    if (index < 0 || index >= widget.episodes.length || index == _index) return;
    setState(() => _index = index);
    _episodeIndex.value = index;
    kurakoMediaSession?.updateEpisode(
      index,
      gestureSeekSeconds: ref.read(settingsProvider).gestureSeekDurationSec,
    );
  }

  Future<void> _playPrev() async {
    if (!_hasPrev) return;
    await _save();
    if (!mounted || !_hasPrev) return;
    _selectEpisode(_index - 1);
    _scheduleOpen();
  }

  Future<void> _playNext({bool auto = false}) async {
    if (!_hasNext) {
      if (auto && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已经是最后一集了')));
      }
      return;
    }
    await _save();
    if (!mounted || !_hasNext) return;
    _selectEpisode(_index + 1);
    _scheduleOpen();
  }

  Future<void> _setRate(double rate) async {
    await _player.setRate(rate);
    if (mounted) setState(() => _rate = rate);
  }

  // Jump forward by the configured quick-seek duration.
  Future<void> _quickSeekForward() async {
    final target =
        Duration(milliseconds: _positionMs) + Duration(seconds: _seekSec);
    final max = Duration(milliseconds: _durationMs);
    await _player.seek(_durationMs > 0 && target > max ? max : target);
  }

  /// Delegate the decision to mpv, whose pause state is authoritative.  The
  /// touch icon below listens to [Player.stream.playing] directly; keeping a
  /// separate optimistic boolean here made the first tap permanently display
  /// the wrong glyph on some mobile backends.
  Future<void> _togglePlaying() async {
    if (_playTogglePending) return;
    _playTogglePending = true;
    try {
      if (_player.state.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (_) {
    } finally {
      _playTogglePending = false;
    }
  }

  Future<void> _setSubDelay(double seconds) async {
    _subDelay = seconds;
    // mpv property: positive delay shows subtitles later.
    await (_player.platform as dynamic)?.setProperty('sub-delay', '$seconds');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _seekDurationSubscription?.close();
    _themeSubscription?.close();
    _settingsSubscription?.close();
    if (_mediaSessionBound) {
      _mediaSessionBound = false;
      final handler = kurakoMediaSession;
      if (handler != null) unawaited(handler.unbind(_player));
    }
    if (Platform.isAndroid && _autoPipConfigured == true) {
      unawaited(_configureAutoPip(false));
    }
    _acceptPlaybackEvents = false;
    _openGeneration.value = ++_openSeq;
    _saveTimer?.cancel();
    _switchDebounce?.cancel();
    _unlockControlTimer?.cancel();
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _tracksSub?.cancel();
    _completedSub?.cancel();
    _logSub?.cancel();
    _errorSub?.cancel();
    _runtimeErrorTimer?.cancel();
    _selectedSubtitle.dispose();
    _episodeIndex.dispose();
    _episodeScrollController?.dispose();
    _save();
    final handle = _handle;
    _handle = null;
    final preparedSubtitle = _preparedExtSub;
    _preparedExtSub = null;
    final disposePlayer = _playerLifecycle.then(
      (_) => _disposePlayback(handle, preparedSubtitle),
    );
    _playerLifecycle = disposePlayer.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint('Player disposal failed: $error\n$stackTrace');
    });
    // Restore portrait orientation + system UI when leaving the player.
    if (_isMobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else if (_fullscreen.value) {
      // Leave the OS window as we found it (windowed) when closing the player.
      windowManager.setFullScreen(false);
    }
    if (!_isMobile) windowManager.removeListener(this);
    _route?.animation?.removeStatusListener(_onRouteStatus);
    _fullscreen.dispose();
    super.dispose();
  }

  Future<void> _disposePlayback(
    PlayableHandle? handle,
    PreparedSubtitle? preparedSubtitle,
  ) async {
    try {
      await _player.dispose();
    } catch (_) {
    } finally {
      await _releasePreparedSubtitle(preparedSubtitle);
      await handle?.release();
      final cache = _subtitleCacheDirectory;
      if (cache != null) {
        try {
          if (await cache.exists()) await cache.delete(recursive: true);
        } catch (_) {}
      }
      // The serialized open pipeline has now drained, so no duration watchdog
      // can still be removing a listener from this notifier.
      _openGeneration.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // One control model for every platform: touch gestures remain available on
    // phones/tablets, while the same surface also understands mouse hover,
    // mouse double-click and hardware-keyboard shortcuts. This avoids giving
    // iPad Stage Manager and Android keyboards a different, weaker player.
    final settings = ref.watch(settingsProvider);
    final video = Video(
      controller: _controller,
      controls: MaterialVideoControls,
      pauseUponEnteringBackgroundMode:
          !settings.backgroundPlayback &&
          !(Platform.isAndroid && settings.autoPictureInPicture),
      resumeUponEnteringForegroundMode: false,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        // libass draws subtitles onto the video texture; hide the Flutter
        // overlay to avoid double text.
        visible: false,
      ),
    );

    final Widget themed = MaterialVideoControlsTheme(
      normal: _mobileTheme(),
      fullscreen: _mobileTheme(),
      child: video,
    );

    // media_kit's long-press speed-up only registers onLongPress/onLongPressEnd
    // — if the system interrupts the gesture (navigation gesture, PiP, an
    // incoming call), the cancel path fires instead of onLongPressEnd and the
    // rate stays stuck at speedUpFactor. Watch raw pointer up/cancel and
    // restore the user's chosen rate shortly after every release.
    final Widget guarded = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (_) => _restoreRateAfterGesture(),
      onPointerCancel: (_) => _restoreRateAfterGesture(),
      child: themed,
    );

    // Once locked, the vendored touch controls suppress their own gestures and
    // UI. This separate button intentionally sits outside that subtree, so a
    // child or an accidental hand touch cannot do anything except unlock.
    final Widget playerBody = Stack(
      fit: StackFit.expand,
      children: [
        guarded,
        if (_controlsLocked)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _showUnlockControl,
          ),
        if (_controlsLocked && _unlockControlVisible)
          _buildUnlockControlsButton(),
      ],
    );

    final dark = Theme.of(context).copyWith(colorScheme: _cs);

    // Every exit (close button, autoplay completion, back gesture) restores the
    // system bars and orientation *before* the previous route lays out. Doing it
    // in dispose() ran after the pop, so the detail page was laid out with the
    // immersive-mode insets and then jumped when the status bar reappeared.
    // Deliberately not a PopScope with canPop:false — that would disable the
    // iOS edge-swipe back gesture; the route animation listener below covers it
    // instead.
    return Theme(
      data: dark,
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.black,
        endDrawer: _buildDrawer(),
        // Open only via the buttons — an edge-swipe would fight the player's
        // horizontal seek gesture.
        endDrawerEnableOpenDragGesture: false,
        body: playerBody,
      ),
    );
  }

  bool _leaving = false;

  /// Restore the system UI, then pop. Awaited so the insets are already correct
  /// when the previous route performs its first layout.
  Future<void> _leavePlayer() async {
    if (_leaving) return;
    _leaving = true;
    await _restoreSystemChrome();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _restoreSystemChrome() async {
    if (!_isMobile) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // The inset change reaches Flutter through the next frame's metrics, so
      // let that frame land before the pop animation starts.
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}
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
      _Panel.superResolution => (
        Icons.auto_fix_high,
        'Anime4K 超分辨率',
        _superResolutionPanel(),
      ),
      _Panel.info => (Icons.info_outline, '播放信息', _infoPanel()),
      _Panel.chapters => (Icons.bookmarks, '章节', _chaptersPanel()),
    };
    return Drawer(
      backgroundColor: cs.surface,
      width: 340,
      // The drawer surface itself must meet the physical right edge.  Applying
      // horizontal SafeArea padding here made an end drawer float inward on
      // landscape iPhones when the notch was on the opposite (left) side.
      child: SafeArea(
        left: false,
        right: false,
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
                      child: Text(
                        title,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                      onPressed: _leavePlayer,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // Body on its own Material so it clips under the title bar.
            Expanded(
              child: Material(color: cs.surface, child: body),
            ),
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
        tile(Icons.auto_fix_high, 'Anime4K 超分辨率', _Panel.superResolution),
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
                  child: Text(
                    '${ep.episodeNo?.toInt() ?? i + 1}',
                    style: TextStyle(fontSize: 11, color: cs.onSurface),
                  ),
                ),
          title: Text(
            ep.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurface),
          ),
          selected: selected,
          selectedTileColor: cs.secondaryContainer,
          onTap: () async {
            Navigator.of(context).pop();
            if (i == _index) return;
            await _save();
            if (!mounted) return;
            _selectEpisode(i);
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

  // Kept as a migration reference while the unified controls are exercised on
  // every platform; the active player now always uses [_mobileTheme].
  // ignore: unused_element
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
          Duration(milliseconds: _positionMs) - const Duration(seconds: 10),
        ),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _player.seek(
              Duration(milliseconds: _positionMs) + const Duration(seconds: 10),
            ),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _player.setVolume((_player.state.volume + 5).clamp(0.0, 100.0)),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _player.setVolume((_player.state.volume - 5).clamp(0.0, 100.0)),
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
        Expanded(child: WindowDragArea(child: _episodeTitleText())),
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
        ValueListenableBuilder<int>(
          valueListenable: _episodeIndex,
          builder: (context, index, _) => MaterialDesktopCustomButton(
            icon: Icon(
              Icons.skip_previous,
              color: index > 0 ? Colors.white : Colors.white30,
            ),
            onPressed: index > 0 ? _playPrev : () {},
          ),
        ),
        const MaterialDesktopPlayOrPauseButton(),
        ValueListenableBuilder<int>(
          valueListenable: _episodeIndex,
          builder: (context, index, _) => MaterialDesktopCustomButton(
            icon: Icon(
              Icons.skip_next,
              color: index < widget.episodes.length - 1
                  ? Colors.white
                  : Colors.white30,
            ),
            onPressed: index < widget.episodes.length - 1
                ? () => _playNext()
                : () {},
          ),
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
                  Text(
                    '${_seekSec}s',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
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
    final appearance = ref.watch(playerAppearanceProvider);
    return MaterialVideoControlsThemeData(
      // The visual controls stay unified across touch and desktop, but a real
      // mouse follows desktop conventions: leaving the whole video hides the
      // controls immediately and an idle pointer disappears with them.
      hideControlsOnMouseExit: true,
      hideMouseOnControlsRemoval: true,
      onMouseDoubleTap: _togglePlaying,
      onSecondaryTap: () => _openPanel(_Panel.menu),
      keyboardShortcuts: {
        const SingleActivator(LogicalKeyboardKey.mediaPlay): () =>
            _player.play(),
        const SingleActivator(LogicalKeyboardKey.mediaPause): () =>
            _player.pause(),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            _player.setVolume(_player.state.volume > 0 ? 0 : 100),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen.value) _toggleFullscreen();
        },
      },
      // Touch gestures.
      seekOnDoubleTap: true,
      // The centre toggles playback while only the two outer quarters seek.
      // The same ratios drive hit-testing and seek-animation placement.
      seekOnDoubleTapLayoutTapsRatios: const [1, 2, 1],
      seekOnDoubleTapLayoutWidgetRatios: const [1, 2, 1],
      volumeGesture: true,
      // screen_brightness has no Linux implementation. Keep the established
      // touch behavior everywhere else while avoiding a dead gesture or a
      // MissingPluginException on Linux desktops.
      brightnessGesture: !Platform.isLinux,
      seekGesture: true,
      controlsLocked: _controlsLocked,
      speedUpOnLongPress: true,
      speedUpFactor: 2.0,
      // Tame the drag sensitivity — the package defaults (vertical 100,
      // horizontal 1000) move brightness/volume/seek far too much per drag.
      // Higher = less sensitive.
      verticalGestureSensitivity: 400,
      horizontalGestureSensitivity: 3000,
      // This gesture has its own duration, independent of the top quick-seek
      // button controlled by [seekDurationProvider].
      seekOnDoubleTapBackwardDuration: Duration(
        seconds: ref.read(settingsProvider).gestureSeekDurationSec,
      ),
      seekOnDoubleTapForwardDuration: Duration(
        seconds: ref.read(settingsProvider).gestureSeekDurationSec,
      ),
      // Keep the picture visible, while taking a little glare off very bright
      // scenes.  The stronger, directional shading lives under the top/bottom
      // bars below instead of covering the middle of the video.
      backdropColor: Colors.transparent,
      edgeShadeColor: const Color(0x66000000),
      // Keep the progress line directly above the compact transport row.
      seekBarThumbColor: _cs.primary,
      seekBarColor: Colors.white70,
      seekBarPositionColor: _cs.primary,
      seekBarBufferColor: Colors.white,
      seekBarHeight: 5.5,
      seekBarThumbSize: 13,
      seekBarMargin: const EdgeInsets.fromLTRB(20, 0, 20, 60),
      seekBarContainerHeight: 32,
      buttonBarHeight: 42,
      buttonBarButtonSize: 26,
      topButtonBarMargin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      bottomButtonBarMargin: const EdgeInsets.only(
        left: 10,
        right: 10,
        bottom: 12,
      ),
      bufferingIndicatorBuilder: (_) => const PlayerBufferingIndicator(),
      verticalGestureIndicatorBuilder: (context, data) {
        final brightness = data.kind == MaterialVerticalGestureKind.brightness;
        return LayoutBuilder(
          builder: (context, constraints) {
            final padding = MediaQuery.paddingOf(context);
            final bounds = Rect.fromLTRB(
              padding.left + 8,
              padding.top + 8,
              constraints.maxWidth - padding.right - 8,
              constraints.maxHeight - padding.bottom - 8,
            );
            final position =
                data.position ??
                Offset(
                  brightness ? bounds.left + 24 : bounds.right - 24,
                  bounds.center.dy,
                );
            final rect = playerLevelIndicatorRect(
              position: position,
              bounds: bounds,
              brightness: brightness,
            );
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: PlayerLevelIndicator(
                    value: data.value,
                    brightness: brightness,
                    color: brightness
                        ? appearance.brightness
                        : appearance.volume,
                  ),
                ),
              ],
            );
          },
        );
      },
      // Top bar: back + title + quick-seek + rate + episode drawer + overflow.
      topButtonBar: [Expanded(child: _readableTopBar())],
      // Do not put a large prev / pause / next group in the middle of the
      // picture.  Chinese video players conventionally keep these frequently
      // used actions at the bottom beside the timestamp, leaving the picture
      // visible while the rest of the controls are shown.
      primaryButtonBar: const [],
      // Bottom bar: timestamp + episode transport + secondary controls.  This
      // preserves our own episode switching path (watch progress, SMB handle
      // release and debounce) instead of media_kit's unrelated playlist skip.
      bottomButtonBar: [Expanded(child: _readableBottomBar())],
    );
  }

  /// Bars stay unfilled: the picture shows through and only the glyphs get a
  /// soft shadow for legibility. Filling them with a rounded surface reads as
  /// a heavy slab over the video.
  Widget _readableBar({required Widget child}) => DefaultTextStyle.merge(
    style: const TextStyle(
      shadows: [Shadow(color: Color(0xBB000000), blurRadius: 4)],
    ),
    child: child,
  );

  Widget _readableTopBar() => _readableBar(
    child: Row(
      children: [
        MaterialCustomButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _popSelf,
        ),
        Expanded(child: WindowDragArea(child: _episodeTitleText())),
        _seekButton(),
        if (Platform.isAndroid)
          MaterialCustomButton(
            icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
            onPressed: _enterPip,
          ),
        _rateButton(),
        MaterialCustomButton(
          icon: Icon(
            _takingScreenshot
                ? Icons.hourglass_top
                : Icons.photo_camera_outlined,
            color: Colors.white,
          ),
          onPressed: _takingScreenshot ? () {} : () => _takeScreenshot(),
        ),
        MaterialCustomButton(
          icon: Icon(
            _controlsLocked ? Icons.lock : Icons.lock_open_outlined,
            color: Colors.white,
          ),
          onPressed: () => _setControlsLocked(!_controlsLocked),
        ),
        MaterialCustomButton(
          icon: const Icon(Icons.tune, color: Colors.white),
          onPressed: () => _openPanel(_Panel.menu),
        ),
        if (!_isMobile) const WindowButtons(light: true),
      ],
    ),
  );

  Widget _readableBottomBar() => _readableBar(
    child: Row(
      children: [
        _touchTransportGroup(),
        const Spacer(),
        if (widget.episodes.length > 1)
          MaterialCustomButton(
            icon: const Icon(Icons.playlist_play, color: Colors.white),
            onPressed: () => _openPanel(_Panel.episodes),
          ),
        if (!_isMobile) _touchFullscreenButton(),
      ],
    ),
  );

  Widget _episodeTitleText() => ValueListenableBuilder<int>(
    valueListenable: _episodeIndex,
    builder: (context, index, _) => Text(
      widget.episodes[index].fileName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 14),
    ),
  );

  /// Compact touch transport group: play/pause → time → previous → next.
  /// Keeping this as one Row makes the
  /// placement deterministic on phones, iPads and narrow Stage Manager panes.
  Widget _touchTransportGroup() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _PlayerPlayPauseButton(player: _player, onTap: _togglePlaying),
      const SizedBox(width: 3),
      const MaterialPositionIndicator(
        style: TextStyle(color: Colors.white, fontSize: 12, height: 1),
      ),
      const SizedBox(width: 7),
      ValueListenableBuilder<int>(
        valueListenable: _episodeIndex,
        builder: (context, index, _) => _compactTouchButton(
          icon: Icons.skip_previous,
          tooltip: '上一集',
          enabled: index > 0,
          onTap: _playPrev,
        ),
      ),
      ValueListenableBuilder<int>(
        valueListenable: _episodeIndex,
        builder: (context, index, _) => _compactTouchButton(
          icon: Icons.skip_next,
          tooltip: '下一集',
          enabled: index < widget.episodes.length - 1,
          onTap: () => _playNext(),
        ),
      ),
    ],
  );

  /// Use 30px-high transport targets instead of Material's default 48px
  /// IconButton footprint. It keeps the controls visibly grouped in the
  /// lower-left corner without sacrificing a usable touch hit area.
  Widget _compactTouchButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
    double iconSize = 23,
  }) => Tooltip(
    message: tooltip,
    child: SizedBox(
      width: icon == Icons.play_arrow || icon == Icons.pause ? 36 : 34,
      height: 30,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Center(
          child: Icon(
            icon,
            size: iconSize,
            color: enabled ? Colors.white : Colors.white30,
          ),
        ),
      ),
    ),
  );

  void _setControlsLocked(bool locked) {
    _unlockControlTimer?.cancel();
    setState(() {
      _controlsLocked = locked;
      _unlockControlVisible = locked;
    });
    if (locked) _scheduleUnlockControlHide();
  }

  void _showUnlockControl() {
    if (!_controlsLocked) return;
    _unlockControlTimer?.cancel();
    if (!_unlockControlVisible) {
      setState(() => _unlockControlVisible = true);
    }
    _scheduleUnlockControlHide();
  }

  void _scheduleUnlockControlHide() {
    _unlockControlTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _controlsLocked) {
        setState(() => _unlockControlVisible = false);
      }
    });
  }

  Widget _buildUnlockControlsButton() => Align(
    alignment: Alignment.centerLeft,
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Material(
          color: Colors.transparent,
          child: IconButton(
            tooltip: '解锁播放器',
            onPressed: () => _setControlsLocked(false),
            icon: const Icon(
              Icons.lock_outline,
              color: Colors.white70,
              size: 24,
              shadows: [Shadow(color: Colors.black, blurRadius: 4)],
            ),
          ),
        ),
      ),
    ),
  );

  /// Windows-touch fullscreen toggle; icon tracks [_fullscreen] live.
  Widget _touchFullscreenButton() => ValueListenableBuilder<bool>(
    valueListenable: _fullscreen,
    builder: (context, fs, _) => MaterialCustomButton(
      icon: Icon(
        fs ? Icons.fullscreen_exit : Icons.fullscreen,
        color: Colors.white,
      ),
      onPressed: _toggleFullscreen,
    ),
  );

  void _popSelf() {
    if (mounted) unawaited(_leavePlayer());
  }

  Widget _rateButton() {
    return MaterialCustomButton(
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, color: Colors.white, size: 20),
          Text(
            '${_rate}x',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
      onPressed: () => _openPanel(_Panel.rate),
    );
  }

  // Quick-seek button: tap jumps forward by the configured duration; long-press
  // opens the duration setting. [_seekSec] is watched by the owning page and
  // included in the keyed controls subtree.  Do not put another Consumer inside
  // media_kit's retained overlay: during route teardown it can outlive this
  // page by one frame and attempt to rebuild a defunct Riverpod element.
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
            Text(
              '${_seekSec}s',
              style: const TextStyle(color: Colors.white, fontSize: 11),
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
            Text(
              '快进 / 快退时长：$local 秒',
              style: TextStyle(color: cs.onSurface, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              '点击顶部快进按钮时跳转的时长（双击画面固定 10 秒）',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
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

  Widget _superResolutionPanel() {
    final cs = _cs;
    final mode = _superResolutionMode;
    const options = <(String, String, String)>[
      ('off', '关闭', '不使用额外图像着色器，负载最低'),
      ('anime4k-light', '轻度', '较少的修复与缩放着色器，适合手机和平板'),
      ('anime4k-balanced', '标准', '更多修复与缩放着色器，GPU 负载、发热与耗电更高'),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            '强度越高越可能增加耗电、发热与掉帧；播放不流畅时请改为轻度或关闭。切换会直接应用到当前视频，不会重新连接 SMB。',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ),
        for (final option in options)
          ListTile(
            leading: option.$1 == mode
                ? Icon(Icons.check_circle, color: cs.primary)
                : const Icon(Icons.radio_button_unchecked),
            title: Text(option.$2, style: TextStyle(color: cs.onSurface)),
            subtitle: Text(
              option.$3,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            selected: option.$1 == mode,
            selectedTileColor: cs.secondaryContainer,
            onTap: () async {
              if (option.$1 == mode) return;
              await ref
                  .read(settingsProvider.notifier)
                  .setSuperResolutionMode(option.$1);
              await _applySuperResolutionMode(option.$1);
              if (mounted) setState(() {});
            },
          ),
      ],
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
            Text(
              '字幕延迟：${_subDelay.toStringAsFixed(1)} 秒',
              style: TextStyle(color: cs.onSurface, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              '正值让字幕更晚出现，负值更早',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
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
    // Scaffold's endDrawer has its own mounted subtree while open. A page-level
    // setState is not a dependable way to repaint that route, so the selection
    // rows listen to the completed subtitle command directly.
    return ValueListenableBuilder<SubtitleTrack>(
      valueListenable: _selectedSubtitle,
      builder: (context, selectedSubtitle, _) {
        final tracks = _player.state.tracks;
        // External subtitle files (loaded via mpv sub-add) also surface in
        // tracks.subtitle with their filename as the title — skip those in the
        // embedded list so each file shows once (in the 外部字幕 section below).
        final extNames = _extSubs.map((s) => s.fileName).toSet();
        final embeddedSubs = tracks.subtitle
            .where(
              (track) =>
                  track.id != 'auto' &&
                  track.id != 'no' &&
                  !(track.title != null && extNames.contains(track.title)),
            )
            .toList();
        // Audio can arrive with duplicate entries over the SMB proxy — dedup
        // by a composite key, and add an index for identical labels.
        final audios = tracks.audio
            .where((track) => track.id != 'auto' && track.id != 'no')
            .toList();
        final seenAudio = <String>{};
        final uniqueAudio = <AudioTrack>[];
        for (final track in audios) {
          final key =
              '${track.id}|${track.title}|${track.language}|${track.codec}';
          if (seenAudio.add(key)) uniqueAudio.add(track);
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _trackHeader(Icons.subtitles, '字幕'),
              _trackTile(
                '关闭字幕',
                selectedSubtitle == SubtitleTrack.no(),
                () async {
                  final disabled = SubtitleTrack.no();
                  await _player.setSubtitleTrack(disabled);
                  if (!mounted) return;
                  setState(() => _activeExtSub = null);
                  await _releaseActivePreparedSubtitle();
                  _selectedSubtitle.value = disabled;
                },
              ),
              for (final subtitle in embeddedSubs)
                _trackTile(
                  _trackLabel(subtitle.title, subtitle.language, subtitle.id),
                  !selectedSubtitle.uri &&
                      !selectedSubtitle.data &&
                      selectedSubtitle == subtitle,
                  () async {
                    await _player.setSubtitleTrack(subtitle);
                    if (!mounted) return;
                    setState(() => _activeExtSub = null);
                    await _releaseActivePreparedSubtitle();
                    _selectedSubtitle.value = subtitle;
                    unawaited(_rememberSub(subtitle));
                  },
                ),
              if (_extSubs.isNotEmpty) ...[
                _trackHeader(Icons.folder_open, '外部字幕'),
                for (final subtitle in _extSubs)
                  _trackTile(
                    subtitle.fileName,
                    _activeExtSub == subtitle.uri,
                    () => _loadExtSub(subtitle),
                  ),
              ],
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.file_open_outlined,
                  color: cs.onSurfaceVariant,
                ),
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
                  _player.state.track.audio.id == uniqueAudio[i].id,
                  () {
                    _player.setAudioTrack(uniqueAudio[i]);
                    _rememberAudio(uniqueAudio[i]);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// Audio track label; appends " · N" when several tracks share the same base
  /// label so identical-language tracks stay distinguishable.
  String _audioLabel(List<AudioTrack> audios, int i) {
    final t = audios[i];
    final base = _trackLabel(t.title, t.language, t.id);
    final sameLabel = audios.where(
      (o) => _trackLabel(o.title, o.language, o.id) == base,
    );
    if (sameLabel.length <= 1) return base;
    final ordinal = audios
        .take(i + 1)
        .where((o) => _trackLabel(o.title, o.language, o.id) == base)
        .length;
    return '$base · $ordinal';
  }

  /// Manual subtitle pick — any subtitle file on the device.
  Future<void> _pickSubtitleFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'ass',
          'srt',
          'ssa',
          'sub',
          'vtt',
          'smi',
          'sami',
          'lrc',
          'mpl',
          'mpl2',
          'sup',
        ],
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
        title: Text(
          _chapters[i].title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurface),
        ),
        trailing: Text(
          _fmtTime(_chapters[i].timeSec),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
        selected: i == currentIdx,
        selectedTileColor: cs.secondaryContainer,
        onTap: () {
          _player.seek(
            Duration(milliseconds: (_chapters[i].timeSec * 1000).round()),
          );
          Navigator.pop(context);
        },
      ),
    );
  }

  // Episode picker moved to the right-side endDrawer (_episodeDrawer); opened
  // via the playlist button / overflow menu.

  // ---- Playback info (video params / decoder / network transfer) ----

  Widget _infoPanel() {
    final proxySourceType =
        _handle != null &&
            (_ep.sourceType == 'smb' || _ep.sourceType == 'webdav') &&
            _handle!.uri.startsWith('http://127.0.0.1')
        ? _ep.sourceType
        : null;
    return _PlaybackInfoSheet(
      player: _player,
      episode: _ep,
      proxySourceType: proxySourceType,
      transportLabel: playbackTransportLabel(_ep, _handle),
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
          Text(
            label,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.bold,
            ),
          ),
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

class _PlayerPlayPauseButton extends StatefulWidget {
  final Player player;
  final Future<void> Function() onTap;
  const _PlayerPlayPauseButton({required this.player, required this.onTap});

  @override
  State<_PlayerPlayPauseButton> createState() => _PlayerPlayPauseButtonState();
}

class _PlayerPlayPauseButtonState extends State<_PlayerPlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  late final StreamSubscription<bool> _subscription;
  late bool _playing = widget.player.state.playing;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      value: _playing ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    _subscription = widget.player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      playing ? _animation.forward() : _animation.reverse();
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _playing ? '暂停' : '播放',
    child: SizedBox(
      width: 36,
      height: 30,
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onTap(),
          child: Center(
            child: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _animation,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              size: 27,
              semanticLabel: _playing ? '暂停' : '播放',
            ),
          ),
        ),
      ),
    ),
  );
}

/// Live playback-info panel: video/audio parameters, decoder state, and network
/// proxy transfer speed. Refreshes once a second while open.
class _PlaybackInfoSheet extends StatefulWidget {
  final Player player;
  final Episode episode;
  final String? proxySourceType;
  final String transportLabel;
  const _PlaybackInfoSheet({
    required this.player,
    required this.episode,
    required this.proxySourceType,
    required this.transportLabel,
  });

  @override
  State<_PlaybackInfoSheet> createState() => _PlaybackInfoSheetState();
}

class _PlaybackInfoSheetState extends State<_PlaybackInfoSheet> {
  Timer? _timer;
  String _hwdec = '…';
  final Map<String, String> _renderInfo = {};
  bool _refreshing = false;
  double? _audioBitrateProp;
  double? _videoBitrateProp;
  String? _containerFormat;
  String? _videoCodecProp;
  String? _audioCodecProp;
  // Network proxy counters: previous sample and derived speed.
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
    if (_refreshing) return;
    _refreshing = true;
    try {
      _hwdec = await _stringProperty('hwdec-current') ?? '未知';
      for (final property in const {
        'mpv-version': 'mpv 版本',
        'current-vo': '视频输出',
        'video-sync': '同步策略（请求）',
        'display-sync-active': '显示同步（实际）',
        'interpolation': '插帧（请求）',
        'avsync': '音视频时差（秒）',
        'frame-drop-count': '输出丢帧累计',
        'decoder-frame-drop-count': '解码丢帧累计',
      }.entries) {
        final value = await _stringProperty(property.key);
        if (value == null) {
          _renderInfo.remove(property.value);
        } else {
          _renderInfo[property.value] = value;
        }
      }
      _audioBitrateProp = await _numericProperty('audio-bitrate');
      _videoBitrateProp = await _numericProperty('video-bitrate');
      _containerFormat = await _stringProperty('file-format');
      _videoCodecProp = await _stringProperty('video-codec');
      _audioCodecProp = await _stringProperty('audio-codec');
      if (widget.proxySourceType != null) {
        try {
          final bytes = switch (widget.proxySourceType) {
            'smb' => await rust.smbProxyStats(),
            'webdav' => await rust.webdavProxyStats(),
            _ => BigInt.zero,
          };
          if (_lastBytes != null) {
            _speedBps = (bytes - _lastBytes!).toDouble();
          }
          _lastBytes = bytes;
          _totalBytes = bytes;
        } catch (_) {}
      }
      if (mounted) setState(() {});
    } finally {
      _refreshing = false;
    }
  }

  Future<String?> _stringProperty(String name) async {
    try {
      final value =
          await (widget.player.platform as dynamic)?.getProperty(name)
              as String?;
      return nonEmptyMediaProperty(value);
    } catch (_) {
      return null;
    }
  }

  Future<double?> _numericProperty(String name) async {
    final raw = await _stringProperty(name);
    return raw == null ? null : double.tryParse(raw);
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
    final videoTrack = widget.player.state.tracks.video
        .where((t) => t.id == tracks.video.id)
        .firstOrNull;
    final audioTrack = widget.player.state.tracks.audio
        .where((t) => t.id == tracks.audio.id)
        .firstOrNull;
    final videoCodec =
        nonEmptyMediaProperty(videoTrack?.codec) ?? _videoCodecProp;
    final audioCodec =
        nonEmptyMediaProperty(audioTrack?.codec) ?? _audioCodecProp;
    final videoBitrate = firstReliableMediaBitrate([
      videoTrack?.bitrate,
      _videoBitrateProp,
    ]);
    final audioBitrate = firstReliableMediaBitrate([
      audioTrack?.bitrate,
      widget.player.state.audioBitrate,
      _audioBitrateProp,
    ]);

    final hwActive = vp.hwPixelformat != null && vp.hwPixelformat!.isNotEmpty;
    final rows = <(String, String)>[
      ('读取方式', widget.transportLabel),
      if (_containerFormat != null) ('封装格式', _containerFormat!),
      if (vp.w != null && vp.h != null) ('分辨率', '${vp.w} × ${vp.h}'),
      if (videoCodec != null && videoCodec.isNotEmpty) ('视频编码', videoCodec),
      if (videoTrack?.decoder case final decoder? when decoder.isNotEmpty)
        ('视频解码器', decoder),
      ('视频码率', formatMediaBitrate(videoBitrate)),
      if (videoTrack?.fps case final fps? when fps > 0)
        ('帧率', '${fps.toStringAsFixed(3)} FPS'),
      (
        '解码方式',
        _hwdec == 'no'
            ? '软件解码'
            : _hwdec == '未知' || _hwdec == '…'
            ? '未知'
            : '硬件解码（$_hwdec）',
      ),
      ..._renderInfo.entries.map((entry) => (entry.key, entry.value)),
      ('纹理渲染后端', '实际后端未由插件上报'),
      if (vp.pixelformat != null) ('像素格式', vp.pixelformat!),
      if (hwActive) ('硬解像素格式', vp.hwPixelformat!),
      if (vp.aspect != null) ('宽高比', vp.aspect!.toStringAsFixed(3)),
      if (vp.colormatrix != null) ('色彩矩阵', vp.colormatrix!),
      if (vp.primaries != null) ('色域', vp.primaries!),
      if (vp.gamma != null) ('传递函数', vp.gamma!),
      if (audioCodec != null && audioCodec.isNotEmpty) ('音频编码', audioCodec),
      if (audioTrack?.decoder case final decoder? when decoder.isNotEmpty)
        ('音频解码器', decoder),
      if (ap.format != null) ('音频格式', ap.format!),
      if (ap.sampleRate != null) ('采样率', '${ap.sampleRate} Hz'),
      if (ap.channels != null) ('声道', ap.channels!),
      ('音频码率', formatMediaBitrate(audioBitrate)),
      if (widget.proxySourceType case final sourceType?) ...[
        (
          '${sourceType == 'webdav' ? 'WebDAV' : 'SMB'} 传输速度',
          _fmtBytes(_speedBps),
        ),
        (
          '${sourceType == 'webdav' ? 'WebDAV' : 'SMB'} 累计流量',
          _fmtTotal(_totalBytes),
        ),
      ],
    ];

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          label,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          style: TextStyle(color: cs.onSurface, fontSize: 13),
                        ),
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
