import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';

/// The list of anime in the library.
final animeListProvider = FutureProvider.autoDispose<List<Anime>>((ref) async {
  return rust.listAnime();
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
final librarySortProvider =
    StateNotifierProvider<_SortNotifier, LibrarySort>((ref) {
  return _SortNotifier();
});

class _SortNotifier extends StateNotifier<LibrarySort> {
  _SortNotifier() : super(LibrarySort.normal) {
    _load();
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
final pinCollectedProvider =
    StateNotifierProvider<_BoolPrefNotifier, bool>((ref) {
  return _BoolPrefNotifier('pin_collected', defaultValue: true);
});

/// Whether the grid is split into labelled sections by the sort dimension.
/// Persisted.
final groupingEnabledProvider =
    StateNotifierProvider<_BoolPrefNotifier, bool>((ref) {
  return _BoolPrefNotifier('grouping_enabled', defaultValue: false);
});

/// A bool backed by SharedPreferences.
class _BoolPrefNotifier extends StateNotifier<bool> {
  final String key;
  _BoolPrefNotifier(this.key, {required bool defaultValue})
      : super(defaultValue) {
    _load(defaultValue);
  }
  Future<void> _load(bool def) async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(key) ?? def;
  }

  Future<void> toggle() => set(!state);

  Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    state = value;
  }
}

/// An int backed by SharedPreferences, clamped to [min, max].
class _IntPrefNotifier extends StateNotifier<int> {
  final String key;
  final int min;
  final int max;
  _IntPrefNotifier(this.key,
      {required int defaultValue, required this.min, required this.max})
      : super(defaultValue) {
    _load(defaultValue);
  }
  Future<void> _load(int def) async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getInt(key) ?? def).clamp(min, max);
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
  const ThemeSettings({this.seedIndex = 0, this.followSystem = true});

  Color get seedColor =>
      kSeedPalette[seedIndex.clamp(0, kSeedPalette.length - 1)].color;

  ThemeSettings copyWith({int? seedIndex, bool? followSystem}) => ThemeSettings(
        seedIndex: seedIndex ?? this.seedIndex,
        followSystem: followSystem ?? this.followSystem,
      );
}

final themeProvider =
    StateNotifierProvider<ThemeNotifier, ThemeSettings>((ref) {
  return ThemeNotifier();
});

class ThemeNotifier extends StateNotifier<ThemeSettings> {
  ThemeNotifier() : super(const ThemeSettings()) {
    _load();
  }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ThemeSettings(
      seedIndex: (prefs.getInt('theme_seed_index') ?? 0)
          .clamp(0, kSeedPalette.length - 1),
      followSystem: prefs.getBool('theme_follow_system') ?? true,
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
}

// ---- Player quick-seek duration (double-tap / quick-forward), persisted ----

/// Seconds jumped by the player's quick-seek (double-tap and the forward
/// button). Adjustable via long-press. Clamped to 5..90.
final seekDurationProvider =
    StateNotifierProvider<_IntPrefNotifier, int>((ref) {
  return _IntPrefNotifier('seek_duration_sec',
      defaultValue: 10, min: 5, max: 90);
});

// ---- UI scale (percent of the adaptive default size), persisted ----

/// Interface scale percentage. 100 = adaptive default; scaled via
/// MaterialApp.builder so vector rendering stays crisp. Clamped to 75..150.
final uiScaleProvider = StateNotifierProvider<_IntPrefNotifier, int>((ref) {
  return _IntPrefNotifier('ui_scale_percent',
      defaultValue: 100, min: 75, max: 150);
});

/// Desktop-only: use the touch-gesture player controls (double-tap seek, swipe
/// volume/brightness) instead of the mouse-hover desktop controls. For
/// touchscreen Windows devices where mouse emulation is clumsy. Persisted.
final touchModePlayerProvider =
    StateNotifierProvider<_BoolPrefNotifier, bool>((ref) {
  return _BoolPrefNotifier('touch_mode_player', defaultValue: false);
});

// ---- Decode mode (player hardware/software acceleration) ----

/// Cached at startup so PlayerPage's static _decodeConfig() can read it
/// without a BuildContext or ProviderRef (VideoControllerConfiguration is
/// fixed at VideoController construction time).
String decodeModeStartupValue = 'auto';

/// Decode mode: 'auto' (platform default), 'hw' (force hardware), 'sw' (force
/// software). Takes effect when next entering the player. Persisted.
final decodeModeProvider =
    StateNotifierProvider<_StringPrefNotifier, String>((ref) {
  return _StringPrefNotifier('decode_mode', defaultValue: 'auto');
});

/// A string backed by SharedPreferences.
class _StringPrefNotifier extends StateNotifier<String> {
  final String key;
  _StringPrefNotifier(this.key, {required String defaultValue})
      : super(defaultValue) {
    _load(defaultValue);
  }
  Future<void> _load(String def) async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(key) ?? def;
    if (key == 'decode_mode') decodeModeStartupValue = state;
  }

  Future<void> set(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    state = value;
    if (key == 'decode_mode') decodeModeStartupValue = value;
  }
}

// ---- Download directory (where SMB downloads are saved) ----

/// App data directory path, cached at startup (for the default download dir).
String appDataDirPath = '';

/// The effective downloads directory: the user-chosen one, or
/// `<data dir>/downloads` when unset.
String effectiveDownloadDir(String pref) =>
    pref.isNotEmpty ? pref : '$appDataDirPath/downloads';

/// Absolute path of the downloads directory. Null = app data dir / downloads.
final downloadDirProvider =
    StateNotifierProvider<_StringPrefNotifier, String>((ref) {
  return _StringPrefNotifier('download_dir', defaultValue: '');
});

// ---- Background download manager (silent SMB downloads) ----

/// One tracked download. Lives from the moment it starts until the user
/// dismisses it after completion. `bytesTotal == 0` means "still connecting".
class DownloadTask {
  final String smbUri;
  final String fileName;
  final int? animeId;
  final int bytesDone;
  final int bytesTotal;
  final String? error;
  final bool done;

  const DownloadTask({
    required this.smbUri,
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
    bool? done,
  }) =>
      DownloadTask(
        smbUri: smbUri,
        fileName: fileName,
        animeId: animeId,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        error: error ?? this.error,
        done: done ?? this.done,
      );
}

/// Runs SMB downloads in the background and exposes their live progress, so the
/// detail page can show a progress icon without a modal dialog blocking play.
/// Completed tasks linger (so the badge stays) until [dismissAnime] clears them.
class DownloadManager extends StateNotifier<List<DownloadTask>> {
  DownloadManager(this._ref) : super(const []);

  final Ref _ref;
  final _subs = <String, dynamic>{};

  bool isDownloading(String smbUri) =>
      state.any((t) => t.smbUri == smbUri && t.active);

  /// Whether an anime has any active or freshly-completed download to surface.
  bool hasFor(int animeId) => state.any((t) => t.animeId == animeId);

  bool hasActiveFor(int animeId) =>
      state.any((t) => t.animeId == animeId && t.active);

  void start(Episode ep, {int? animeId}) {
    if (isDownloading(ep.filePath)) return;
    final destDir = effectiveDownloadDir(_ref.read(downloadDirProvider));
    state = [
      ...state,
      DownloadTask(
        smbUri: ep.filePath,
        fileName: ep.fileName,
        animeId: animeId,
      ),
    ];
    final stream =
        rust.smbDownload(smbUri: ep.filePath, destDir: destDir);
    _subs[ep.filePath] = stream.listen(
      (p) => _update(
        ep.filePath,
        (t) => t.copyWith(
          bytesDone: p.bytesDone.toInt(),
          bytesTotal: p.bytesTotal.toInt(),
        ),
      ),
      onError: (Object e) =>
          _update(ep.filePath, (t) => t.copyWith(error: '$e')),
      onDone: () {
        _subs.remove(ep.filePath);
        _update(ep.filePath, (t) {
          final ok = t.error == null && t.bytesTotal > 0;
          return t.copyWith(done: true, bytesDone: ok ? t.bytesTotal : null);
        });
      },
    );
  }

  Future<void> cancel(String smbUri) async {
    await rust.smbCancelDownload(smbUri: smbUri);
    _subs.remove(smbUri);
    state = state.where((t) => t.smbUri != smbUri).toList();
  }

  /// Clear lingering completed/failed tasks for an anime once the user has seen
  /// them. Active downloads are kept.
  void dismissAnime(int animeId) {
    state = state
        .where((t) => !(t.animeId == animeId && !t.active))
        .toList();
  }

  void _update(String smbUri, DownloadTask Function(DownloadTask) f) {
    state = [
      for (final t in state)
        if (t.smbUri == smbUri) f(t) else t,
    ];
  }
}

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, List<DownloadTask>>((ref) {
  return DownloadManager(ref);
});

/// Whether an SMB source is configured — gates the detail-page download UI.
final smbConfiguredProvider = FutureProvider.autoDispose<bool>((ref) async {
  final creds = await SmbCredentials.load();
  return creds.isConfigured;
});

// ---- Bangumi API mirror (default on; routes API through the China mirror) ----

/// When on, Bangumi API calls go through the mainland-China mirror
/// (bgmapi.anibt.net) and cover images through bgmimg.anibt.net. Persisted;
/// pushed into the Rust core on change. Thanks to Soyorin (github.com/
/// Yuri-NagaSaki/bangumi-proxy) for the public proxy.
final bangumiMirrorProvider =
    StateNotifierProvider<_MirrorNotifier, bool>((ref) {
  return _MirrorNotifier();
});

class _MirrorNotifier extends StateNotifier<bool> {
  _MirrorNotifier() : super(true) {
    _load();
  }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('bangumi_mirror') ?? true;
    rust.setBangumiMirror(enabled: state);
  }

  Future<void> set(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bangumi_mirror', value);
    rust.setBangumiMirror(enabled: value);
    state = value;
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

  static Future<SmbCredentials> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SmbCredentials(
      host: prefs.getString('smb_host') ?? '',
      share: prefs.getString('smb_share') ?? '',
      user: prefs.getString('smb_user') ?? '',
      password: prefs.getString('smb_password') ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('smb_host', host);
    await prefs.setString('smb_share', share);
    await prefs.setString('smb_user', user);
    await prefs.setString('smb_password', password);
  }

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

// ---- Settings (player choice, OAuth token, external player) ----

class Settings {
  final bool useExternalPlayer;
  final String externalPlayerPath;
  final String bangumiToken;
  // Persisted OAuth session.
  final String bangumiRefreshToken;
  final int bangumiTokenExpiresAt; // Unix seconds; 0 = none.

  const Settings({
    this.useExternalPlayer = false,
    this.externalPlayerPath = '',
    this.bangumiToken = '',
    this.bangumiRefreshToken = '',
    this.bangumiTokenExpiresAt = 0,
  });

  bool get isLoggedIn => bangumiToken.isNotEmpty;

  Settings copyWith({
    bool? useExternalPlayer,
    String? externalPlayerPath,
    String? bangumiToken,
    String? bangumiRefreshToken,
    int? bangumiTokenExpiresAt,
  }) {
    return Settings(
      useExternalPlayer: useExternalPlayer ?? this.useExternalPlayer,
      externalPlayerPath: externalPlayerPath ?? this.externalPlayerPath,
      bangumiToken: bangumiToken ?? this.bangumiToken,
      bangumiRefreshToken: bangumiRefreshToken ?? this.bangumiRefreshToken,
      bangumiTokenExpiresAt:
          bangumiTokenExpiresAt ?? this.bangumiTokenExpiresAt,
    );
  }
}

class SettingsNotifier extends StateNotifier<Settings> {
  SettingsNotifier() : super(const Settings()) {
    ready = _load();
  }

  /// Completes when the persisted settings have been read from disk. Await this
  /// before reading settings for a decision (e.g. which player to launch) —
  /// otherwise the very first read after launch sees the default state because
  /// [_load] hasn't finished yet.
  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = Settings(
      useExternalPlayer: prefs.getBool('use_external_player') ?? false,
      externalPlayerPath: prefs.getString('external_player_path') ?? '',
      bangumiToken: prefs.getString('bangumi_token') ?? '',
      bangumiRefreshToken: prefs.getString('bangumi_refresh_token') ?? '',
      bangumiTokenExpiresAt: prefs.getInt('bangumi_token_expires_at') ?? 0,
    );
    // Push any existing access token into Rust and refresh if near expiry.
    if (state.bangumiToken.isNotEmpty) {
      rust.setBangumiToken(token: state.bangumiToken);
      await _refreshIfNeeded();
    }
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

  /// Persist a freshly obtained OAuth session (access + refresh + expiry).
  Future<void> setOAuthSession({
    required String accessToken,
    required String refreshToken,
    required int expiresAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bangumi_token', accessToken);
    await prefs.setString('bangumi_refresh_token', refreshToken);
    await prefs.setInt('bangumi_token_expires_at', expiresAt);
    rust.setBangumiToken(token: accessToken.isEmpty ? null : accessToken);
    state = state.copyWith(
      bangumiToken: accessToken,
      bangumiRefreshToken: refreshToken,
      bangumiTokenExpiresAt: expiresAt,
    );
  }

  /// Clear the OAuth session (logout).
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bangumi_token');
    await prefs.remove('bangumi_refresh_token');
    await prefs.remove('bangumi_token_expires_at');
    rust.setBangumiToken(token: null);
    state = state.copyWith(
      bangumiToken: '',
      bangumiRefreshToken: '',
      bangumiTokenExpiresAt: 0,
    );
  }

  /// Refresh the access token if it expires within a day. Credentials are baked
  /// into the Rust core. Best-effort; failures are ignored (user can re-login).
  Future<void> _refreshIfNeeded() async {
    final s = state;
    if (s.bangumiRefreshToken.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Refresh proactively within 24h of expiry (tokens live ~7 days).
    if (s.bangumiTokenExpiresAt - now > 86400) return;
    try {
      final result =
          await rust.oauthRefresh(refreshToken: s.bangumiRefreshToken);
      await setOAuthSession(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.expiresAt,
      );
    } catch (_) {
      // Leave the stale token in place; user can re-login.
    }
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, Settings>((
  ref,
) {
  return SettingsNotifier();
});
