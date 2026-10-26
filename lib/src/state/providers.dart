import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:material_ui/material_ui.dart' show Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/bangumi_credentials.dart';
import '../services/bangumi_mirror.dart';
import '../services/bangumi_oauth.dart' show OAuthException;
import '../services/cover_repository.dart';
import '../services/download_storage.dart';
import '../services/security_scope.dart';
import '../rust/api.dart' as rust;
import '../rust/models.dart';

/// The list of anime in the library.
final animeListProvider = FutureProvider.autoDispose<List<Anime>>((ref) async {
  final anime = await rust.listAnime();
  CoverRepository.instance.warmLibrary(
    anime.map((item) => item.coverUrl),
    BangumiMirrorService.instance,
  );
  return anime;
});

/// A single anime's detail (refreshes when invalidated).
final animeDetailProvider = FutureProvider.autoDispose.family<Anime?, int>((
  ref,
  id,
) async {
  return rust.getAnime(id: id);
});

/// Episodes belonging to an anime.
final episodesProvider = FutureProvider.autoDispose.family<List<Episode>, int>((
  ref,
  animeId,
) async {
  return rust.listEpisodes(animeId: animeId);
});

/// Library folders.
final foldersProvider = FutureProvider.autoDispose<List<LibraryFolder>>((
  ref,
) async {
  return rust.listLibraryFolders();
});

// ---- Library sorting & grouping ----

enum LibrarySort { normal, year, rating, weekday, yearWeekday, yearQuarter }

/// The active library sort, persisted so the choice carries over across
/// launches.
final librarySortProvider = NotifierProvider<_SortNotifier, LibrarySort>(
  _SortNotifier.new,
);

class _SortNotifier extends Notifier<LibrarySort> {
  @override
  LibrarySort build() {
    _load();
    return LibrarySort.normal;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final i = prefs.getInt('library_sort') ?? 0;
    if (i >= 0 && i < LibrarySort.values.length) {
      state = LibrarySort.values[i];
    }
  }

  Future<void> set(LibrarySort value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('library_sort', value.index);
    state = value;
  }
}

/// Whether collected entries (在看/想看/…) are pinned above the rest. When off,
/// they sort purely by the chosen order like everything else. Persisted.
final pinCollectedProvider = NotifierProvider<_BoolPrefNotifier, bool>(
  () => _BoolPrefNotifier('pin_collected', defaultValue: true),
);

/// Whether the grid is split into labelled sections by the sort dimension.
/// Persisted.
final groupingEnabledProvider = NotifierProvider<_BoolPrefNotifier, bool>(
  () => _BoolPrefNotifier('grouping_enabled', defaultValue: false),
);

/// A bool backed by SharedPreferences.
class _BoolPrefNotifier extends Notifier<bool> {
  _BoolPrefNotifier(this.key, {required this._defaultValue});

  final String key;
  final bool _defaultValue;

  @override
  bool build() {
    _load();
    return _defaultValue;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(key) ?? _defaultValue;
  }

  Future<void> toggle() => set(!state);

  Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    state = value;
  }
}

/// An int backed by SharedPreferences, clamped to [min, max].
class _IntPrefNotifier extends Notifier<int> {
  _IntPrefNotifier(
    this.key, {
    required this._defaultValue,
    required this.min,
    required this.max,
  });

  final String key;
  final int min;
  final int max;
  final int _defaultValue;

  @override
  int build() {
    _load();
    return _defaultValue;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getInt(key) ?? _defaultValue).clamp(min, max);
  }

  Future<void> set(int value) async {
    final v = value.clamp(min, max);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, v);
    state = v;
  }
}

// ---- Theme color (preset seed palette + follow-system Monet) ----

/// A selectable seed color for the Material 3 theme.
class SeedChoice {
  final String label;
  final Color color;
  const SeedChoice(this.label, this.color);
}

/// Preset MD3 seed palette. Index 0 is the historical default (deep purple).
const kSeedPalette = <SeedChoice>[
  SeedChoice('默认紫', Color(0xFF6750A4)),
  SeedChoice('樱花粉', Color(0xFFB3325A)),
  SeedChoice('绯红', Color(0xFFBA1A1A)),
  SeedChoice('琥珀橙', Color(0xFF825500)),
  SeedChoice('森绿', Color(0xFF386A20)),
  SeedChoice('青碧', Color(0xFF00696E)),
  SeedChoice('海蓝', Color(0xFF0061A4)),
  SeedChoice('靛蓝', Color(0xFF4355B9)),
];

class ThemeSettings {
  final int seedIndex;
  final bool followSystem; // Android Monet
  final AppThemeMode mode;
  const ThemeSettings({
    this.seedIndex = 0,
    this.followSystem = true,
    this.mode = AppThemeMode.system,
  });

  Color get seedColor =>
      kSeedPalette[seedIndex.clamp(0, kSeedPalette.length - 1)].color;

  ThemeSettings copyWith({
    int? seedIndex,
    bool? followSystem,
    AppThemeMode? mode,
  }) => ThemeSettings(
    seedIndex: seedIndex ?? this.seedIndex,
    followSystem: followSystem ?? this.followSystem,
    mode: mode ?? this.mode,
  );
}

enum AppThemeMode {
  system,
  light,
  dark;

  ThemeMode get flutterThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  static AppThemeMode fromStorage(String? value) => switch (value) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeSettings>(
  ThemeNotifier.new,
);

class ThemeNotifier extends Notifier<ThemeSettings> {
  @override
  ThemeSettings build() {
    _load();
    return const ThemeSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ThemeSettings(
      seedIndex: (prefs.getInt('theme_seed_index') ?? 0).clamp(
        0,
        kSeedPalette.length - 1,
      ),
      followSystem: prefs.getBool('theme_follow_system') ?? true,
      mode: AppThemeMode.fromStorage(prefs.getString('theme_mode')),
    );
  }

  Future<void> setSeedIndex(int i) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_seed_index', i);
    state = state.copyWith(seedIndex: i);
  }

  Future<void> setFollowSystem(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('theme_follow_system', v);
    state = state.copyWith(followSystem: v);
  }

  Future<void> setMode(AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
    state = state.copyWith(mode: mode);
  }
}

// ---- Player toolbar quick-forward duration, persisted ----

/// Seconds jumped by the player's toolbar quick-forward button. Double-tap
/// gestures use Settings.gestureSeekDurationSec independently. Clamped 5..90.
final seekDurationProvider = NotifierProvider<_IntPrefNotifier, int>(
  () =>
      _IntPrefNotifier('seek_duration_sec', defaultValue: 40, min: 5, max: 90),
);

// ---- UI scale (percent of the adaptive default size), persisted ----

/// Interface scale percentage. 100 = adaptive default; scaled via
/// MaterialApp.builder so vector rendering stays crisp. Clamped to 75..150.
final uiScaleProvider = NotifierProvider<_IntPrefNotifier, int>(
  () => _IntPrefNotifier(
    'ui_scale_percent',
    defaultValue: 100,
    min: 75,
    max: 150,
  ),
);

// ---- Remember window size (desktop), persisted ----

/// Desktop-only appearance toggle: reopen the window with the size (and
/// maximized state) it had when last used, instead of the fixed default.
/// The geometry itself lives in the `window_width` / `window_height` /
/// `window_maximized` prefs, written by the app root's WindowListener.
final rememberWindowSizeProvider = NotifierProvider<_BoolPrefNotifier, bool>(
  () => _BoolPrefNotifier('remember_window_size', defaultValue: true),
);

/// On desktop, use touch gestures instead of mouse-hover controls. On iPad,
/// this is inverted at the presentation layer: false keeps the touch-first
/// default and true opts into desktop controls for a mouse/keyboard setup.
/// Persisted across launches.
final touchModePlayerProvider = NotifierProvider<_BoolPrefNotifier, bool>(
  () => _BoolPrefNotifier('touch_mode_player', defaultValue: false),
);

/// Use the operating-system default font instead of the bundled LXGW WenKai.
/// Off by default (the app ships its own screen-tuned CJK font). Persisted.
final useSystemFontProvider = NotifierProvider<_BoolPrefNotifier, bool>(
  () => _BoolPrefNotifier('use_system_font', defaultValue: false),
);

// ---- Decode mode (player hardware/software acceleration) ----

/// Cached at startup so PlayerPage's static _decodeConfig() can read it
/// without a BuildContext or ProviderRef (VideoControllerConfiguration is
/// fixed at VideoController construction time).
String decodeModeStartupValue = 'auto';

/// Automatic, software or a platform-specific mpv decoder candidate. Legacy
/// 'hw' is treated as automatic. Takes effect when next entering the player.
final decodeModeProvider = NotifierProvider<_StringPrefNotifier, String>(
  () => _StringPrefNotifier('decode_mode', defaultValue: 'auto'),
);

/// A string backed by SharedPreferences.
class _StringPrefNotifier extends Notifier<String> {
  _StringPrefNotifier(this.key, {required this._defaultValue});

  final String key;
  final String _defaultValue;

  @override
  String build() {
    _load();
    return _defaultValue;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    state = prefs.getString(key) ?? _defaultValue;
    if (key == 'decode_mode') decodeModeStartupValue = state;
    if (key == 'download_dir') await _syncDownloadDirectory(state);
  }

  Future<void> set(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    if (!ref.mounted) return;
    state = value;
    if (key == 'decode_mode') decodeModeStartupValue = value;
    if (key == 'download_dir') await _syncDownloadDirectory(value);
  }

  Future<void> _syncDownloadDirectory(String value) async {
    final effective = effectiveDownloadDir(value);
    if (effective.isEmpty) return;
    await rust.setDownloadDirectory(downloadDir: effective);
  }
}

// ---- Download directory (where SMB downloads are saved) ----

/// App data directory path, cached at startup (for the default download dir).
String appDataDirPath = '';

/// Default SMB download location, initialized by main. On iOS this is the
/// Files-visible Documents/Kurako Downloads folder.
String defaultDownloadDirPath = '';

/// The effective downloads directory: the user-chosen one, or
/// `<data dir>/downloads` when unset.
String effectiveDownloadDir(String pref) => pref.isNotEmpty
    ? pref
    : (defaultDownloadDirPath.isNotEmpty
          ? defaultDownloadDirPath
          : '$appDataDirPath/downloads');

/// Absolute path of the downloads directory. Null = app data dir / downloads.
final downloadDirProvider = NotifierProvider<_StringPrefNotifier, String>(
  () => _StringPrefNotifier('download_dir', defaultValue: ''),
);

enum OnboardingStatus { loading, required, completed }

/// Whether the first-run setup has loaded and is required. The loading state
/// prevents an existing installation from seeing the onboarding page for one
/// frame while SharedPreferences is still being read.
final onboardingCompletedProvider =
    NotifierProvider<OnboardingCompletedNotifier, OnboardingStatus>(
      OnboardingCompletedNotifier.new,
    );

class OnboardingCompletedNotifier extends Notifier<OnboardingStatus> {
  @override
  OnboardingStatus build() {
    ready = _load();
    return OnboardingStatus.loading;
  }

  late final Future<void> ready;
  static const _key = 'onboarding_completed_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (ref.mounted) {
      state = (prefs.getBool(_key) ?? false)
          ? OnboardingStatus.completed
          : OnboardingStatus.required;
    }
  }

  /// Marks setup as done and returns the stored value.
  Future<bool> complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    if (ref.mounted) state = OnboardingStatus.completed;
    return true;
  }
}

// ---- Background download manager (silent SMB downloads) ----

/// One tracked download. Lives from the moment it starts until the user
/// dismisses it after completion. `bytesTotal == 0` means "still connecting".
class DownloadTask {
  final String sourceUri;
  final String sourceType;
  final String fileName;
  final int? animeId;
  final int bytesDone;
  final int bytesTotal;
  final String? error;
  final bool done;

  const DownloadTask({
    required this.sourceUri,
    required this.sourceType,
    required this.fileName,
    this.animeId,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.error,
    this.done = false,
  });

  double? get progress => bytesTotal > 0 ? bytesDone / bytesTotal : null;
  bool get active => !done && error == null;

  DownloadTask copyWith({
    int? bytesDone,
    int? bytesTotal,
    String? error,
    bool clearError = false,
    bool? done,
  }) => DownloadTask(
    sourceUri: sourceUri,
    sourceType: sourceType,
    fileName: fileName,
    animeId: animeId,
    bytesDone: bytesDone ?? this.bytesDone,
    bytesTotal: bytesTotal ?? this.bytesTotal,
    error: clearError ? null : (error ?? this.error),
    done: done ?? this.done,
  );
}

/// Runs SMB downloads in the background and exposes their live progress, so the
/// detail page can show a progress icon without a modal dialog blocking play.
/// Completed tasks linger (so the badge stays) until [dismissAnime] clears them.
class DownloadManager extends Notifier<List<DownloadTask>> {
  DownloadManager({AndroidMediaStoreStorage? mediaStore})
    : _mediaStore = mediaStore ?? AndroidMediaStoreStorage();

  final AndroidMediaStoreStorage _mediaStore;
  final _subs = <String, StreamSubscription<DownloadProgress>>{};
  final _reservations = <String, MediaStoreReservation>{};

  @override
  List<DownloadTask> build() => const [];

  bool isDownloading(String sourceUri) =>
      state.any((task) => task.sourceUri == sourceUri && task.active);

  /// Whether an anime has any active or freshly-completed download to surface.
  bool hasFor(int animeId) => state.any((t) => t.animeId == animeId);

  bool hasActiveFor(int animeId) =>
      state.any((t) => t.animeId == animeId && t.active);

  void start(Episode ep, {int? animeId}) {
    if (isDownloading(ep.filePath)) return;
    if (ep.sourceType != 'smb' && ep.sourceType != 'webdav') return;
    final destDir = effectiveDownloadDir(ref.read(downloadDirProvider));
    state = [
      ...state,
      DownloadTask(
        sourceUri: ep.filePath,
        sourceType: ep.sourceType,
        fileName: ep.fileName,
        animeId: animeId,
      ),
    ];
    unawaited(_runDownload(ep, destDir, animeId));
  }

  /// macOS: a user-chosen download folder needs its security scope active for
  /// the whole write, or the first download after a relaunch fails with EPERM.
  /// The default folder is covered by the app's movies entitlement instead and
  /// has no bookmark, so a missing bookmark means "use the path as-is" rather
  /// than a hard failure. The scope is released when the stream ends.
  Future<void> _runDownload(Episode ep, String destDir, int? animeId) async {
    if (AndroidMediaStoreStorage.supported) {
      await _runMediaStoreDownload(ep, animeId);
      return;
    }
    ScopedPath? scope;
    if (Platform.isMacOS) {
      try {
        scope = await SecurityScope.access(destDir);
      } on SecurityScopeException {
        // No bookmark for this folder (default location or an unmounted
        // volume): fall through and let the write decide.
      }
    }
    final target = scope?.path ?? destDir;
    final stream = ep.sourceType == 'webdav'
        ? rust.webdavDownload(remoteUri: ep.filePath, destDir: target)
        : rust.smbDownload(smbUri: ep.filePath, destDir: target);
    _subs[ep.filePath] = stream.listen(
      (p) {
        // A failure arrives as a terminal stream event: the generated wrapper
        // drops the function's Result, so an Err would otherwise look like a
        // clean end-of-stream and the UI would claim success.
        final failure = p.error;
        if (failure != null) {
          _update(ep.filePath, (t) => t.copyWith(error: failure));
          return;
        }
        _update(
          ep.filePath,
          (t) => t.copyWith(
            bytesDone: p.bytesDone.toInt(),
            bytesTotal: p.bytesTotal.toInt(),
          ),
        );
      },
      onError: (Object e) {
        _update(ep.filePath, (t) => t.copyWith(error: '$e'));
        _releaseScope(scope);
      },
      onDone: () {
        _subs.remove(ep.filePath);
        _releaseScope(scope);
        var completed = false;
        _update(ep.filePath, (t) {
          // Never claim completion without a recorded error state and a real
          // transferred size; a zero-byte "success" is not a download.
          final ok = t.error == null && t.bytesTotal > 0;
          completed = ok;
          return t.copyWith(
            done: ok,
            error: ok ? null : (t.error ?? '下载未完成，请重试'),
            clearError: ok,
            bytesDone: ok ? t.bytesTotal : null,
          );
        });
        if (completed) {
          final affectedAnimeId = animeId;
          if (affectedAnimeId != null) {
            ref.invalidate(episodesProvider(affectedAnimeId));
          }
        }
      },
    );
  }

  Future<void> _runMediaStoreDownload(Episode ep, int? animeId) async {
    MediaStoreReservation? reservation;
    var terminalError = '';
    try {
      reservation = await _mediaStore.reserveVideo(ep.fileName);
      _reservations[ep.filePath] = reservation;
      final stream = rust.networkDownloadToFd(
        remoteUri: ep.filePath,
        fd: reservation.fd,
      );
      _subs[ep.filePath] = stream.listen(
        (progress) {
          final failure = progress.error;
          if (failure != null) terminalError = failure;
          _update(
            ep.filePath,
            (task) => task.copyWith(
              bytesDone: progress.bytesDone.toInt(),
              bytesTotal: progress.bytesTotal.toInt(),
              error: failure,
            ),
          );
        },
        onError: (Object error) {
          terminalError = '$error';
          _update(ep.filePath, (task) => task.copyWith(error: terminalError));
        },
        onDone: () {
          _subs.remove(ep.filePath);
          unawaited(
            _finishMediaStoreDownload(
              ep: ep,
              animeId: animeId,
              reservation: reservation!,
              terminalError: terminalError,
            ),
          );
        },
      );
    } catch (error) {
      if (reservation != null) {
        try {
          await _mediaStore.abort(reservation.uri);
        } catch (_) {}
      }
      _reservations.remove(ep.filePath);
      _update(ep.filePath, (task) => task.copyWith(error: '$error'));
    }
  }

  Future<void> _finishMediaStoreDownload({
    required Episode ep,
    required int? animeId,
    required MediaStoreReservation reservation,
    required String terminalError,
  }) async {
    _reservations.remove(ep.filePath);
    var published = false;
    try {
      if (terminalError.isNotEmpty) throw StateError(terminalError);
      final stat = await _mediaStore.stat(reservation.uri);
      if (stat.size <= 0) throw StateError('下载文件为空');
      await _mediaStore.publish(reservation.uri);
      published = true;
      await rust.recordDownload(
        remoteUri: ep.filePath,
        localUri: reservation.uri,
        bytesTotal: stat.size,
      );
      await _downloadMediaStoreSubtitles(ep, reservation.displayName);
      _update(
        ep.filePath,
        (task) => task.copyWith(
          done: true,
          bytesDone: stat.size,
          bytesTotal: stat.size,
          clearError: true,
        ),
      );
      if (animeId != null) ref.invalidate(episodesProvider(animeId));
    } catch (error) {
      try {
        if (published) {
          await _mediaStore.deleteMedia(
            reservation.uri,
            videoName: reservation.displayName,
          );
        } else {
          await _mediaStore.abort(reservation.uri);
        }
      } catch (_) {}
      _update(ep.filePath, (task) => task.copyWith(error: '$error'));
    }
  }

  Future<void> _downloadMediaStoreSubtitles(
    Episode ep,
    String videoName,
  ) async {
    try {
      final candidates = ep.sourceType == 'webdav'
          ? await rust.webdavListSubtitles(remoteUri: ep.filePath)
          : await rust.smbListSubtitles(smbUri: ep.filePath);
      for (final candidate in candidates) {
        MediaStoreReservation? reservation;
        try {
          reservation = await _mediaStore.reserveSubtitle(candidate.fileName);
          await _downloadFdToCompletion(candidate.uri, reservation.fd);
          final stat = await _mediaStore.stat(reservation.uri);
          if (stat.size <= 0) throw StateError('字幕文件为空');
          await _mediaStore.publish(reservation.uri);
          reservation = null;
        } catch (error) {
          debugPrint('MediaStore subtitle skipped: $error');
          if (reservation != null) {
            try {
              await _mediaStore.abort(reservation.uri);
            } catch (_) {}
          }
        }
      }
    } catch (error) {
      debugPrint('MediaStore subtitle discovery skipped: $error');
    }
  }

  Future<void> _downloadFdToCompletion(String remoteUri, int fd) async {
    final completer = Completer<void>();
    late final StreamSubscription<DownloadProgress> subscription;
    subscription = rust
        .networkDownloadToFd(remoteUri: remoteUri, fd: fd)
        .listen(
          (progress) {
            final error = progress.error;
            if (error != null && !completer.isCompleted) {
              completer.completeError(StateError(error));
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );
    try {
      await completer.future.timeout(const Duration(minutes: 2));
    } finally {
      await subscription.cancel();
    }
  }

  void _releaseScope(ScopedPath? scope) {
    if (scope != null) unawaited(SecurityScope.release(scope.scopePath));
  }

  Future<void> cancel(String sourceUri) async {
    // Cancel the progress subscription FIRST: a late event from the old stream
    // must not resurrect the task we're about to remove, or pollute a
    // re-download of the same episode started right afterwards.
    await _subs.remove(sourceUri)?.cancel();
    final reservation = _reservations.remove(sourceUri);
    if (reservation != null) {
      try {
        await _mediaStore.abort(reservation.uri);
      } catch (_) {}
    }
    final task = state.where((task) => task.sourceUri == sourceUri).firstOrNull;
    if (task?.sourceType == 'webdav') {
      await rust.webdavCancelDownload(remoteUri: sourceUri);
    } else {
      await rust.smbCancelDownload(smbUri: sourceUri);
    }
    state = state.where((task) => task.sourceUri != sourceUri).toList();
  }

  /// Clear lingering completed/failed tasks for an anime once the user has seen
  /// them. Active downloads are kept.
  void dismissAnime(int animeId) {
    final next = state
        .where((t) => !(t.animeId == animeId && !t.active))
        .toList();
    if (next.length != state.length) state = next;
  }

  void _update(String sourceUri, DownloadTask Function(DownloadTask) f) {
    state = [
      for (final t in state)
        if (t.sourceUri == sourceUri) f(t) else t,
    ];
  }
}

final downloadManagerProvider =
    NotifierProvider<DownloadManager, List<DownloadTask>>(DownloadManager.new);

/// Whether an SMB source is configured — gates the detail-page download UI.
final smbConfiguredProvider = FutureProvider.autoDispose<bool>((ref) async {
  final creds = await SmbCredentials.load();
  return creds.isConfigured;
});

// ---- Bangumi API mirror ----

final bangumiMirrorProvider = NotifierProvider<_MirrorNotifier, bool>(
  _MirrorNotifier.new,
);

final bangumiMirrorStatusProvider =
    NotifierProvider<_MirrorStatusNotifier, BangumiMirrorService>(
      _MirrorStatusNotifier.new,
    );

class _MirrorStatusNotifier extends Notifier<BangumiMirrorService> {
  @override
  BangumiMirrorService build() {
    final service = BangumiMirrorService.instance;
    service.addListener(_changed);
    ref.onDispose(() => service.removeListener(_changed));
    return service;
  }

  void _changed() {
    // Re-assigning the same instance; updateShouldNotify forces the notify.
    if (ref.mounted) state = BangumiMirrorService.instance;
  }

  @override
  bool updateShouldNotify(
    BangumiMirrorService old,
    BangumiMirrorService current,
  ) => true;
}

class _MirrorNotifier extends Notifier<bool> {
  @override
  bool build() {
    BangumiMirrorService.instance.addListener(_sync);
    ref.onDispose(() => BangumiMirrorService.instance.removeListener(_sync));
    unawaited(_load());
    return false;
  }

  void _sync() {
    if (ref.mounted) state = BangumiMirrorService.instance.enabled;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await BangumiMirrorService.instance.restore(
      requestedEnabled: prefs.getBool('bangumi_mirror') ?? false,
    );
    _sync();
    // Push the saved per-feature choices before any request can be made.
    await _pushRouteOptions(prefs);
    if (BangumiMirrorService.instance.enabled) {
      try {
        final anime = await rust.listAnime();
        CoverRepository.instance.warmLibrary(
          anime.map((item) => item.coverUrl),
          BangumiMirrorService.instance,
        );
      } catch (_) {}
    }
  }

  static Future<void> _pushRouteOptions(SharedPreferences prefs) async {
    try {
      await rust.setBangumiRouteOptions(
        oauthViaMirror: prefs.getBool('bangumi_oauth_via_mirror') ?? false,
        collectionViaMirror:
            prefs.getBool('bangumi_collection_via_mirror') ?? false,
      );
    } catch (_) {}
  }

  Future<void> set(bool value) async {
    if (!value) await BangumiMirrorService.instance.disable();
    final enabled = value && BangumiMirrorService.instance.enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bangumi_mirror', enabled);
    if (ref.mounted) state = enabled;
  }
}

/// Whether Bangumi login (OAuth) may go through the reverse proxy.
/// Independent of the collection choice; a token works on either host.
final bangumiOAuthViaMirrorProvider =
    NotifierProvider<_RouteFlagNotifier, bool>(
      () => _RouteFlagNotifier('bangumi_oauth_via_mirror'),
    );

/// Whether collection reads/writes may go through the reverse proxy.
final bangumiCollectionViaMirrorProvider =
    NotifierProvider<_RouteFlagNotifier, bool>(
      () => _RouteFlagNotifier('bangumi_collection_via_mirror'),
    );

class _RouteFlagNotifier extends Notifier<bool> {
  _RouteFlagNotifier(this._key);

  final String _key;

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (ref.mounted) state = prefs.getBool(_key) ?? false;
  }

  Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
    if (ref.mounted) state = value;
    await _MirrorNotifier._pushRouteOptions(prefs);
  }
}

// ---- SMB credentials (persisted; pushed into the Rust smb client) ----

class SmbCredentials {
  final String host;
  final String share;
  final String user;
  final String password;
  const SmbCredentials({
    required this.host,
    required this.share,
    required this.user,
    required this.password,
  });

  bool get isConfigured => host.isNotEmpty && share.isNotEmpty;

  String get historyLabel {
    final account = user.trim().isEmpty ? '匿名' : user.trim();
    return '$host / $share · $account';
  }

  static const _historyKey = 'smb_connection_history_v1';

  static Future<SmbCredentials> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SmbCredentials(
      host: prefs.getString('smb_host') ?? '',
      share: prefs.getString('smb_share') ?? '',
      user: prefs.getString('smb_user') ?? '',
      password: prefs.getString('smb_password') ?? '',
    );
  }

  static Future<List<SmbCredentials>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <SmbCredentials>[];
    for (final source in prefs.getStringList(_historyKey) ?? const <String>[]) {
      try {
        final value = jsonDecode(source);
        if (value is! Map<String, dynamic>) continue;
        final host = value['host'];
        final share = value['share'];
        final user = value['user'];
        final password = value['password'];
        if (host is! String ||
            share is! String ||
            user is! String ||
            password is! String ||
            host.trim().isEmpty ||
            share.trim().isEmpty) {
          continue;
        }
        result.add(
          SmbCredentials(
            host: host,
            share: share,
            user: user,
            password: password,
          ),
        );
      } catch (_) {
        // Ignore only the malformed history row; active credentials remain.
      }
    }
    return result;
  }

  Future<void> save({bool rememberInHistory = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('smb_host', host);
    await prefs.setString('smb_share', share);
    await prefs.setString('smb_user', user);
    await prefs.setString('smb_password', password);
    if (rememberInHistory && isConfigured) {
      final history = await loadHistory();
      final identity = _historyIdentity;
      history.removeWhere((entry) => entry._historyIdentity == identity);
      history.insert(0, this);
      await prefs.setStringList(
        _historyKey,
        history
            .take(10)
            .map(
              (entry) => jsonEncode({
                'host': entry.host,
                'share': entry.share,
                'user': entry.user,
                'password': entry.password,
              }),
            )
            .toList(),
      );
    }
  }

  String get _historyIdentity =>
      '${host.trim().toLowerCase()}\n${share.trim().toLowerCase()}\n${user.trim().toLowerCase()}';

  /// Push credentials into the Rust SMB client (no network round-trip).
  void pushToRust() {
    if (!isConfigured) return;
    rust.smbSetCredentials(
      host: host,
      share: share,
      user: user,
      password: password,
    );
  }
}

class WebDavCredentials {
  final String baseUrl;
  final String user;
  final String password;
  final String authMode;
  final bool allowInsecureTls;

  const WebDavCredentials({
    required this.baseUrl,
    required this.user,
    required this.password,
    required this.authMode,
    this.allowInsecureTls = false,
  });

  bool get isConfigured => baseUrl.isNotEmpty;

  String get historyLabel {
    final account = authMode == 'anonymous' || user.trim().isEmpty
        ? '匿名'
        : user.trim();
    return '$baseUrl · $account';
  }

  static const _historyKey = 'webdav_connection_history_v1';

  static Future<WebDavCredentials> load() async {
    final prefs = await SharedPreferences.getInstance();
    return WebDavCredentials(
      baseUrl: prefs.getString('webdav_base_url') ?? '',
      user: prefs.getString('webdav_user') ?? '',
      password: prefs.getString('webdav_password') ?? '',
      authMode: prefs.getString('webdav_auth_mode') ?? 'basic',
      allowInsecureTls: prefs.getBool('webdav_allow_insecure_tls') ?? false,
    );
  }

  static Future<List<WebDavCredentials>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <WebDavCredentials>[];
    for (final source in prefs.getStringList(_historyKey) ?? const <String>[]) {
      try {
        final value = jsonDecode(source);
        if (value is! Map<String, dynamic>) continue;
        final baseUrl = value['baseUrl'];
        final user = value['user'];
        final password = value['password'];
        final authMode = value['authMode'];
        final allowInsecureTls = value['allowInsecureTls'];
        if (baseUrl is! String ||
            user is! String ||
            password is! String ||
            authMode is! String ||
            allowInsecureTls is! bool ||
            baseUrl.trim().isEmpty ||
            (authMode != 'basic' && authMode != 'anonymous')) {
          continue;
        }
        result.add(
          WebDavCredentials(
            baseUrl: baseUrl,
            user: user,
            password: password,
            authMode: authMode,
            allowInsecureTls: allowInsecureTls,
          ),
        );
      } catch (_) {
        // Ignore only the malformed history row; active credentials remain.
      }
    }
    return result;
  }

  Future<void> save({bool rememberInHistory = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webdav_base_url', baseUrl);
    await prefs.setString('webdav_user', user);
    await prefs.setString('webdav_password', password);
    await prefs.setString('webdav_auth_mode', authMode);
    await prefs.setBool('webdav_allow_insecure_tls', allowInsecureTls);
    if (rememberInHistory && isConfigured) {
      final history = await loadHistory();
      final identity = _historyIdentity;
      history.removeWhere((entry) => entry._historyIdentity == identity);
      history.insert(0, this);
      await prefs.setStringList(
        _historyKey,
        history
            .take(10)
            .map(
              (entry) => jsonEncode({
                'baseUrl': entry.baseUrl,
                'user': entry.user,
                'password': entry.password,
                'authMode': entry.authMode,
                'allowInsecureTls': entry.allowInsecureTls,
              }),
            )
            .toList(),
      );
    }
  }

  String get _historyIdentity =>
      '${baseUrl.trim().toLowerCase()}\n${user.trim().toLowerCase()}\n$authMode';

  Future<void> pushToRust() => rust.webdavSetCredentials(
    baseUrl: baseUrl,
    user: user,
    password: password,
    authMode: authMode,
    allowInsecureTls: allowInsecureTls,
  );
}

final webDavConfiguredProvider = FutureProvider.autoDispose<bool>((ref) async {
  return (await WebDavCredentials.load()).isConfigured;
});

// ---- Settings (player choice, OAuth token, external player) ----

class Settings {
  final bool useExternalPlayer;
  final String externalPlayerPath;
  final String bangumiToken;
  // Persisted OAuth session.
  final String bangumiRefreshToken;
  final int bangumiTokenExpiresAt; // Unix seconds; 0 = none.
  /// Which credential is active. A personal access token is not an OAuth
  /// session: no refresh token, no queryable expiry, nothing auto-renews it.
  final BangumiAuthKind bangumiAuthKind;

  /// Display-only identity of the logged-in account (both kinds fill it when
  /// known). Not a secret; safe for the settings card.
  final int bangumiUserId;
  final String bangumiUsername;

  /// Whether a personal-token credential was actually restored from the
  /// secure store this session. Runtime state, never persisted here.
  final bool personalTokenActive;

  /// `off` or `anime4k-lite`. Applied the next time a video is opened.
  final String superResolutionMode;
  final bool autoResumePlayback;
  final bool autoPlayNext;
  final bool backgroundPlayback;
  final bool autoPictureInPicture;
  final bool mediaSessionEnabled;
  final int gestureSeekDurationSec;

  const Settings({
    this.useExternalPlayer = false,
    this.externalPlayerPath = '',
    this.bangumiToken = '',
    this.bangumiRefreshToken = '',
    this.bangumiTokenExpiresAt = 0,
    this.bangumiAuthKind = BangumiAuthKind.oauth,
    this.bangumiUserId = 0,
    this.bangumiUsername = '',
    this.personalTokenActive = false,
    this.superResolutionMode = 'off',
    this.autoResumePlayback = true,
    this.autoPlayNext = true,
    this.backgroundPlayback = false,
    this.autoPictureInPicture = false,
    this.mediaSessionEnabled = false,
    this.gestureSeekDurationSec = 10,
  });

  bool get isLoggedIn => switch (bangumiAuthKind) {
    BangumiAuthKind.oauth => bangumiToken.isNotEmpty,
    BangumiAuthKind.personalAccessToken => personalTokenActive,
  };

  Settings copyWith({
    bool? useExternalPlayer,
    String? externalPlayerPath,
    String? bangumiToken,
    String? bangumiRefreshToken,
    int? bangumiTokenExpiresAt,
    BangumiAuthKind? bangumiAuthKind,
    int? bangumiUserId,
    String? bangumiUsername,
    bool? personalTokenActive,
    String? superResolutionMode,
    bool? autoResumePlayback,
    bool? autoPlayNext,
    bool? backgroundPlayback,
    bool? autoPictureInPicture,
    bool? mediaSessionEnabled,
    int? gestureSeekDurationSec,
  }) {
    return Settings(
      useExternalPlayer: useExternalPlayer ?? this.useExternalPlayer,
      externalPlayerPath: externalPlayerPath ?? this.externalPlayerPath,
      bangumiToken: bangumiToken ?? this.bangumiToken,
      bangumiRefreshToken: bangumiRefreshToken ?? this.bangumiRefreshToken,
      bangumiTokenExpiresAt:
          bangumiTokenExpiresAt ?? this.bangumiTokenExpiresAt,
      bangumiAuthKind: bangumiAuthKind ?? this.bangumiAuthKind,
      bangumiUserId: bangumiUserId ?? this.bangumiUserId,
      bangumiUsername: bangumiUsername ?? this.bangumiUsername,
      personalTokenActive: personalTokenActive ?? this.personalTokenActive,
      superResolutionMode: superResolutionMode ?? this.superResolutionMode,
      autoResumePlayback: autoResumePlayback ?? this.autoResumePlayback,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      backgroundPlayback: backgroundPlayback ?? this.backgroundPlayback,
      autoPictureInPicture: autoPictureInPicture ?? this.autoPictureInPicture,
      mediaSessionEnabled: mediaSessionEnabled ?? this.mediaSessionEnabled,
      gestureSeekDurationSec:
          gestureSeekDurationSec ?? this.gestureSeekDurationSec,
    );
  }
}

enum BangumiRefreshStatus {
  ready,
  refreshing,
  success,
  networkFailure,
  reloginRequired,
}

/// Display-safe metadata only: never tokens or backend errors.
class BangumiRefreshState {
  final BangumiRefreshStatus status;
  final DateTime? lastSuccess;
  final int expiresAt;

  const BangumiRefreshState({
    this.status = BangumiRefreshStatus.ready,
    this.lastSuccess,
    this.expiresAt = 0,
  });
}

class BangumiRefreshStateNotifier extends Notifier<BangumiRefreshState> {
  @override
  BangumiRefreshState build() => const BangumiRefreshState();

  void update(BangumiRefreshState value) {
    if (ref.mounted) state = value;
  }
}

final bangumiRefreshStateProvider =
    NotifierProvider<BangumiRefreshStateNotifier, BangumiRefreshState>(
      BangumiRefreshStateNotifier.new,
    );

/// Tests replace this boundary without initializing Rust or using real OAuth.
abstract class BangumiRefreshBackend {
  Future<rust.OAuthResult> refresh(String refreshToken);
  Future<void> setAccessToken(String? token);
}

class RustBangumiRefreshBackend implements BangumiRefreshBackend {
  const RustBangumiRefreshBackend();

  @override
  Future<rust.OAuthResult> refresh(String refreshToken) =>
      rust.oauthRefresh(refreshToken: refreshToken);

  @override
  Future<void> setAccessToken(String? token) =>
      rust.setBangumiToken(token: token);
}

final bangumiRefreshBackendProvider = Provider<BangumiRefreshBackend>(
  (ref) => const RustBangumiRefreshBackend(),
);

/// Tests replace this boundary without initializing Rust.
abstract class BangumiPersonalTokenBackend {
  /// Validate a personal token via `/v0/me`; returns the identity only.
  Future<({int userId, String username})> validate(String token);
}

class RustBangumiPersonalTokenBackend implements BangumiPersonalTokenBackend {
  const RustBangumiPersonalTokenBackend();

  @override
  Future<({int userId, String username})> validate(String token) async {
    final profile = await rust.validatePersonalAccessToken(token: token);
    return (userId: profile.userId, username: profile.username);
  }
}

final bangumiPersonalTokenBackendProvider =
    Provider<BangumiPersonalTokenBackend>(
      (ref) => const RustBangumiPersonalTokenBackend(),
    );

class SettingsNotifier extends Notifier<Settings> {
  SettingsNotifier({
    BangumiRefreshBackend? refreshBackend,
    BangumiPersonalTokenBackend? personalTokenBackend,
    this.credentialStore,
    this.onRefreshStateChanged,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : _injectedRefreshBackend = refreshBackend,
       _injectedPersonalTokenBackend = personalTokenBackend,
       _injectedOnRefreshStateChanged = onRefreshStateChanged,
       _now = now ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  final BangumiRefreshBackend? _injectedRefreshBackend;
  final BangumiPersonalTokenBackend? _injectedPersonalTokenBackend;
  final void Function(BangumiRefreshState)? _injectedOnRefreshStateChanged;
  final BangumiCredentialStore? credentialStore;
  void Function(BangumiRefreshState)? onRefreshStateChanged;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  late final BangumiRefreshBackend _refreshBackend;
  late final BangumiPersonalTokenBackend _personalTokenBackend;
  BangumiRefreshState refreshState = const BangumiRefreshState();
  int _sessionGeneration = 0;
  bool _disposed = false;
  bool _loginInProgress = false;
  Future<void> _sessionWrites = Future<void>.value();

  @override
  Settings build() {
    _refreshBackend =
        _injectedRefreshBackend ?? ref.read(bangumiRefreshBackendProvider);
    _personalTokenBackend =
        _injectedPersonalTokenBackend ??
        ref.read(bangumiPersonalTokenBackendProvider);
    onRefreshStateChanged = _injectedOnRefreshStateChanged;
    onRefreshStateChanged ??= ref
        .read(bangumiRefreshStateProvider.notifier)
        .update;
    // StateNotifier's dispose() work: flag stale sessions and stop the timer
    // when the container tears this notifier down.
    ref.onDispose(() {
      _disposed = true;
      _sessionGeneration++;
      _refreshTimer?.cancel();
    });
    ready = _load();
    // Renewal waits for ready, so _load must never await renewal.
    unawaited(ready.then((_) => ensureFreshBangumiToken()));
    return const Settings();
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  void _publishRefresh(BangumiRefreshStatus status, {DateTime? lastSuccess}) {
    if (_disposed) return;
    refreshState = BangumiRefreshState(
      status: status,
      lastSuccess: lastSuccess ?? refreshState.lastSuccess,
      expiresAt: state.bangumiTokenExpiresAt,
    );
    onRefreshStateChanged?.call(refreshState);
  }

  /// Completes when the persisted settings have been read from disk. Await this
  /// before reading settings for a decision (e.g. which player to launch) —
  /// otherwise the very first read after launch sees the default state because
  /// [_load] hasn't finished yet.
  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final backgroundPlayback = prefs.getBool('background_playback') ?? false;
    final mediaSessionEnabled =
        (prefs.getBool('media_session_enabled') ?? false) || backgroundPlayback;
    if (backgroundPlayback) {
      await prefs.setBool('media_session_enabled', true);
    }
    if (_disposed) return;
    final authKind = BangumiAuthKind.fromPersisted(
      prefs.getString('bangumi_auth_kind'),
    );
    state = Settings(
      useExternalPlayer: prefs.getBool('use_external_player') ?? false,
      externalPlayerPath: prefs.getString('external_player_path') ?? '',
      bangumiToken: prefs.getString('bangumi_token') ?? '',
      bangumiRefreshToken: prefs.getString('bangumi_refresh_token') ?? '',
      bangumiTokenExpiresAt: prefs.getInt('bangumi_token_expires_at') ?? 0,
      bangumiAuthKind: authKind,
      bangumiUserId: prefs.getInt('bangumi_user_id') ?? 0,
      bangumiUsername: prefs.getString('bangumi_username') ?? '',
      superResolutionMode: _normalizeSuperResolutionMode(
        prefs.getString('super_resolution_mode') ?? 'off',
      ),
      autoResumePlayback: prefs.getBool('auto_resume_playback') ?? true,
      autoPlayNext: prefs.getBool('auto_play_next') ?? true,
      backgroundPlayback: backgroundPlayback,
      autoPictureInPicture: prefs.getBool('auto_picture_in_picture') ?? false,
      mediaSessionEnabled: mediaSessionEnabled,
      gestureSeekDurationSec: (prefs.getInt('gesture_seek_duration_sec') ?? 10)
          .clamp(5, 90),
    );
    final lastSuccess = prefs.getInt('bangumi_refresh_last_success');
    _publishRefresh(
      BangumiRefreshStatus.ready,
      lastSuccess: lastSuccess == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSuccess),
    );
    // A personal-token session is restored from the secure store. When the
    // store is unreadable or the token is gone there is no fallback: the app
    // starts logged out and the user pastes a token again.
    var personalTokenActive = false;
    String? personalToken;
    if (authKind == BangumiAuthKind.personalAccessToken) {
      final store = credentialStore;
      if (store != null) {
        // macOS: the token may still live in the (prompt-happy) keychain
        // from an older build — move it to the container file once.
        if (store is FileBangumiCredentialStore) {
          await store.migrateFromKeychainOnce(prefs);
        }
        try {
          personalToken = await store.readPersonalToken();
        } catch (_) {
          // Runtime storage errors are not safe to display or log verbatim.
        }
      }
      personalTokenActive = personalToken != null && personalToken.isNotEmpty;
    }
    if (_disposed) return;
    state = state.copyWith(personalTokenActive: personalTokenActive);
    if (state.isLoggedIn) {
      final runtimeToken = authKind == BangumiAuthKind.personalAccessToken
          ? personalToken
          : state.bangumiToken;
      if (runtimeToken != null && runtimeToken.isNotEmpty) {
        try {
          await _refreshBackend.setAccessToken(runtimeToken);
        } catch (_) {
          // Runtime setup errors are not safe to display or log verbatim.
        }
      }
    }
    if (!_disposed) _startRefreshTimer();
  }

  /// Reuse an in-flight refresh so overlapping triggers (startup, app-resume,
  /// periodic timer) never fire duplicate network requests.
  Future<void>? _refreshing;
  Timer? _refreshTimer;

  /// How long before expiry we start trying to renew. Wide (3 days of a ~7-day
  /// token) so there are many chances to succeed even when the official OAuth
  /// domain is only intermittently reachable.
  static const int _refreshWindowSecs = 3 * 24 * 3600;

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    // Long-running instances (desktop especially) can cross the expiry point
    // without ever backgrounding, so poll periodically rather than relying on
    // an app restart to trigger renewal.
    _refreshTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(ensureFreshBangumiToken());
    });
  }

  Future<void> setUseExternalPlayer(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_external_player', value);
    state = state.copyWith(useExternalPlayer: value);
  }

  Future<void> setExternalPlayerPath(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('external_player_path', value);
    state = state.copyWith(externalPlayerPath: value);
  }

  Future<void> setSuperResolutionMode(String value) async {
    value = _normalizeSuperResolutionMode(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('super_resolution_mode', value);
    state = state.copyWith(superResolutionMode: value);
  }

  Future<void> setAutoResumePlayback(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_resume_playback', value);
    state = state.copyWith(autoResumePlayback: value);
  }

  Future<void> setAutoPlayNext(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_play_next', value);
    state = state.copyWith(autoPlayNext: value);
  }

  /// Android background playback runs as a foreground media service, so it
  /// cannot be enabled without exposing the corresponding system controls.
  Future<void> setBackgroundPlayback(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_playback', value);
    if (value) {
      await prefs.setBool('media_session_enabled', true);
    }
    state = state.copyWith(
      backgroundPlayback: value,
      mediaSessionEnabled: value ? true : state.mediaSessionEnabled,
    );
  }

  Future<void> setAutoPictureInPicture(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_picture_in_picture', value);
    state = state.copyWith(autoPictureInPicture: value);
  }

  Future<void> setMediaSessionEnabled(bool value) async {
    if (!value && state.backgroundPlayback) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('media_session_enabled', value);
    state = state.copyWith(mediaSessionEnabled: value);
  }

  Future<void> setGestureSeekDurationSec(int value) async {
    final normalized = value.clamp(5, 90);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('gesture_seek_duration_sec', normalized);
    state = state.copyWith(gestureSeekDurationSec: normalized);
  }

  Future<void> resetPlayerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    const values = <String, Object>{
      'use_external_player': false,
      'external_player_path': '',
      'super_resolution_mode': 'off',
      'auto_resume_playback': true,
      'auto_play_next': true,
      'background_playback': false,
      'auto_picture_in_picture': false,
      'media_session_enabled': false,
      'gesture_seek_duration_sec': 10,
    };
    for (final entry in values.entries) {
      final saved = switch (entry.value) {
        bool value => await prefs.setBool(entry.key, value),
        int value => await prefs.setInt(entry.key, value),
        String value => await prefs.setString(entry.key, value),
        _ => false,
      };
      if (!saved) throw StateError('无法重置播放器设置 ${entry.key}');
    }
    state = state.copyWith(
      useExternalPlayer: false,
      externalPlayerPath: '',
      superResolutionMode: 'off',
      autoResumePlayback: true,
      autoPlayNext: true,
      backgroundPlayback: false,
      autoPictureInPicture: false,
      mediaSessionEnabled: false,
      gestureSeekDurationSec: 10,
    );
  }

  static String _normalizeSuperResolutionMode(String value) => switch (value) {
    'anime4k-lite' => 'anime4k-balanced',
    'anime4k-light' || 'anime4k-balanced' || 'off' => value,
    _ => 'off',
  };

  /// Call before opening authorization so an old refresh cannot finish during it.
  void beginBangumiLogin() {
    if (_disposed) return;
    _sessionGeneration++;
    _loginInProgress = true;
    _refreshing = null;
    _publishRefresh(BangumiRefreshStatus.ready);
  }

  void endBangumiLogin() {
    if (!_disposed) _loginInProgress = false;
  }

  /// New authorization invalidates all results from the previous session.
  Future<void> setOAuthSession({
    required String accessToken,
    required String refreshToken,
    required int expiresAt,
    int userId = 0,
  }) {
    final generation = ++_sessionGeneration;
    _loginInProgress = false;
    _refreshing = null;
    return _queueSessionWrite(() async {
      await ready;
      if (!_isCurrent(generation)) return;
      refreshState = const BangumiRefreshState();
      await _saveSession(
        generation: generation,
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        userId: userId,
      );
    });
  }

  /// Validate and activate a pasted personal access token.
  ///
  /// Nothing is overwritten until `/v0/me` has confirmed the token: a
  /// rejected or unreadable token leaves the previous session untouched. The
  /// token is stored in the platform secure store only.
  Future<void> loginWithPersonalAccessToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const OAuthException('personal token empty');
    }
    final store = credentialStore;
    if (store == null) {
      throw const OAuthException('secure storage unavailable');
    }
    final profile = await _personalTokenBackend.validate(trimmed);
    await store.writePersonalToken(trimmed);
    final generation = ++_sessionGeneration;
    _loginInProgress = false;
    _refreshing = null;
    return _queueSessionWrite(() async {
      await ready;
      if (!_isCurrent(generation)) return;
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(generation)) return;
      // An OAuth session and a personal token are never merged: the previous
      // session's keys all go away first.
      for (final key in const [
        'bangumi_token',
        'bangumi_refresh_token',
        'bangumi_token_expires_at',
        'bangumi_refresh_last_success',
      ]) {
        await prefs.remove(key);
        if (!_isCurrent(generation)) return;
      }
      await prefs.setString(
        'bangumi_auth_kind',
        BangumiAuthKind.personalAccessToken.persistedValue,
      );
      if (!_isCurrent(generation)) return;
      await prefs.setInt('bangumi_user_id', profile.userId);
      if (!_isCurrent(generation)) return;
      await prefs.setString('bangumi_username', profile.username);
      if (!_isCurrent(generation)) return;
      await _refreshBackend.setAccessToken(trimmed);
      if (!_isCurrent(generation)) return;
      refreshState = const BangumiRefreshState();
      state = state.copyWith(
        bangumiToken: '',
        bangumiRefreshToken: '',
        bangumiTokenExpiresAt: 0,
        bangumiAuthKind: BangumiAuthKind.personalAccessToken,
        bangumiUserId: profile.userId,
        bangumiUsername: profile.username,
        personalTokenActive: true,
      );
      _publishRefresh(BangumiRefreshStatus.ready);
    });
  }

  Future<void> _queueSessionWrite(Future<void> Function() action) {
    final operation = _sessionWrites.then((_) => action());
    // A failed persistence attempt must not block later logout/login writes.
    _sessionWrites = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _saveSession({
    required int generation,
    required String accessToken,
    required String refreshToken,
    required int expiresAt,
    int userId = 0,
    DateTime? lastSuccess,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (!_isCurrent(generation)) return;
    await prefs.setString('bangumi_token', accessToken);
    if (!_isCurrent(generation)) return;
    await prefs.setString('bangumi_refresh_token', refreshToken);
    if (!_isCurrent(generation)) return;
    await prefs.setInt('bangumi_token_expires_at', expiresAt);
    if (!_isCurrent(generation)) return;
    await prefs.setString(
      'bangumi_auth_kind',
      BangumiAuthKind.oauth.persistedValue,
    );
    if (!_isCurrent(generation)) return;
    if (userId > 0) {
      await prefs.setInt('bangumi_user_id', userId);
      if (!_isCurrent(generation)) return;
    }
    if (lastSuccess == null) {
      await prefs.remove('bangumi_refresh_last_success');
    } else {
      await prefs.setInt(
        'bangumi_refresh_last_success',
        lastSuccess.millisecondsSinceEpoch,
      );
    }
    if (!_isCurrent(generation)) return;
    await _refreshBackend.setAccessToken(
      accessToken.isEmpty ? null : accessToken,
    );
    if (!_isCurrent(generation)) return;
    state = state.copyWith(
      bangumiToken: accessToken,
      bangumiRefreshToken: refreshToken,
      bangumiTokenExpiresAt: expiresAt,
      bangumiAuthKind: BangumiAuthKind.oauth,
      bangumiUserId: userId > 0 ? userId : state.bangumiUserId,
      personalTokenActive: false,
    );
    _publishRefresh(
      lastSuccess == null
          ? BangumiRefreshStatus.ready
          : BangumiRefreshStatus.success,
      lastSuccess: lastSuccess,
    );
  }

  /// Invalidate in-flight requests immediately, then serialize the disk clear.
  Future<void> logout() {
    final generation = ++_sessionGeneration;
    _loginInProgress = false;
    _refreshing = null;
    final kind = state.bangumiAuthKind;
    return _queueSessionWrite(() async {
      await ready;
      if (!_isCurrent(generation)) return;
      if (kind == BangumiAuthKind.personalAccessToken) {
        // A failed secure-store delete must not trap the user in a logged-in
        // state: the kind flag below already keeps the leftover token from
        // being restored or used.
        try {
          await credentialStore?.deletePersonalToken();
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(generation)) return;
      for (final key in const [
        'bangumi_token',
        'bangumi_refresh_token',
        'bangumi_token_expires_at',
        'bangumi_refresh_last_success',
        'bangumi_auth_kind',
        'bangumi_user_id',
        'bangumi_username',
      ]) {
        await prefs.remove(key);
        if (!_isCurrent(generation)) return;
      }
      await _refreshBackend.setAccessToken(null);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        bangumiToken: '',
        bangumiRefreshToken: '',
        bangumiTokenExpiresAt: 0,
        bangumiAuthKind: BangumiAuthKind.oauth,
        bangumiUserId: 0,
        bangumiUsername: '',
        personalTokenActive: false,
      );
      refreshState = const BangumiRefreshState();
      _publishRefresh(BangumiRefreshStatus.ready);
    });
  }

  /// Startup/resume/timer/manual triggers await disk loading and share a request.
  Future<void> ensureFreshBangumiToken({bool force = false}) async {
    final generation = _sessionGeneration;
    await ready;
    await _sessionWrites;
    if (!_isCurrent(generation) || _loginInProgress) return;
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    late final Future<void> future;
    future = _doRefresh(force: force, generation: generation).whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
    _refreshing = future;
    return future;
  }

  /// Interpret only known protocol/transport markers. Raw errors never leave
  /// this boundary; unknown failures are visible but are not blindly retried.
  static ({BangumiRefreshStatus status, bool retryable}) _refreshFailure(
    Object error,
  ) {
    final text = error.toString().toLowerCase();
    if (RegExp(
          r'oauth error:\s*(invalid_grant|invalid_token|access_denied|unauthorized_client)\b',
        ).hasMatch(text) ||
        RegExp(r'http 40[13]\b').hasMatch(text)) {
      return (status: BangumiRefreshStatus.reloginRequired, retryable: false);
    }
    final retryable =
        text.contains('oauth token request') ||
        text.contains('socketexception') ||
        text.contains('timeoutexception') ||
        text.contains('connection reset') ||
        RegExp(r'http (408|429|5\d\d)\b').hasMatch(text) ||
        RegExp(r'oauth error:\s*(server_error|temporarily_unavailable)\b')
            .hasMatch(text);
    return (status: BangumiRefreshStatus.networkFailure, retryable: retryable);
  }

  Future<void> _doRefresh({
    required bool force,
    required int generation,
  }) async {
    if (!_isCurrent(generation) || !state.isLoggedIn) return;
    // A personal access token has no refresh flow at all. It lives until it
    // is rejected; the UI shows its expiry as unknown.
    if (state.bangumiAuthKind == BangumiAuthKind.personalAccessToken) {
      return;
    }
    final refreshToken = state.bangumiRefreshToken;
    final expiresAt = state.bangumiTokenExpiresAt;
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    if (refreshToken.isEmpty) {
      if (force || (expiresAt > 0 && expiresAt <= now)) {
        _publishRefresh(BangumiRefreshStatus.reloginRequired);
      }
      return;
    }
    // Definitively rejected credentials need authorization, not resume retries.
    if (refreshState.status == BangumiRefreshStatus.reloginRequired) return;
    if (!force && expiresAt > 0 && expiresAt - now > _refreshWindowSecs) return;
    _publishRefresh(BangumiRefreshStatus.refreshing);
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!_isCurrent(generation)) return;
      rust.OAuthResult result;
      try {
        result = await _refreshBackend.refresh(refreshToken);
      } catch (error) {
        if (!_isCurrent(generation)) return;
        final failure = _refreshFailure(error);
        if (kDebugMode) {
          debugPrint('Bangumi renewal: ${failure.status.name}');
        }
        if (!failure.retryable || attempt == 2) {
          _publishRefresh(failure.status);
          return;
        }
        await _wait(Duration(seconds: 2 << attempt));
        continue;
      }
      if (!_isCurrent(generation)) return;
      if (result.accessToken.isEmpty) {
        _publishRefresh(BangumiRefreshStatus.reloginRequired);
        return;
      }
      try {
        await _queueSessionWrite(() async {
          if (!_isCurrent(generation)) return;
          await _saveSession(
            generation: generation,
            accessToken: result.accessToken,
            refreshToken: result.refreshToken.isEmpty
                ? refreshToken
                : result.refreshToken,
            expiresAt: result.expiresAt,
            lastSuccess: _now(),
          );
        });
      } catch (_) {
        // Do not repeat token rotation when only the local save/runtime failed.
        if (_isCurrent(generation)) {
          _publishRefresh(BangumiRefreshStatus.networkFailure);
        }
      }
      return;
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  () => SettingsNotifier(credentialStore: createPlatformCredentialStore()),
);

/// Restore every SharedPreferences-backed option to its default and clear the
/// matching Rust runtime state. Library/database cleanup is deliberately owned
/// by the caller so downloaded media can be preserved independently.
Future<void> resetPersistedAppSettings() async {
  final prefs = await SharedPreferences.getInstance();
  await BangumiMirrorService.instance.disable();
  final cleared = await prefs.clear();
  if (!cleared) {
    throw StateError('无法清空软件配置');
  }

  decodeModeStartupValue = 'auto';
  await rust.setBangumiToken(token: null);
  await rust.setBangumiMirror(enabled: false);
  // The personal access token lives outside SharedPreferences: clear the
  // credential store too so a settings reset really logs the account out.
  try {
    await createPlatformCredentialStore().deletePersonalToken();
  } catch (_) {
    // An unavailable store holds nothing to clear.
  }
  await rust.smbSetCredentials(host: '', share: '', user: '', password: '');
  await rust.webdavSetCredentials(
    baseUrl: '',
    user: '',
    password: '',
    authMode: 'basic',
    allowInsecureTls: false,
  );
  final downloadDir = effectiveDownloadDir('');
  if (downloadDir.isNotEmpty) {
    await rust.setDownloadDirectory(downloadDir: downloadDir);
  }
}
