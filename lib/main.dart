import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'src/rust/frb_generated.dart';
import 'src/rust/api.dart' as rust;
import 'src/rust/api/mirror.dart' as mirror;
import 'src/services/bangumi_mirror.dart';
import 'src/app.dart';
import 'src/state/providers.dart';
import 'src/services/proxy.dart';
import 'src/services/media_session.dart';
import 'src/services/security_scope.dart';
import 'src/services/download_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerBundledLicenses();
  MediaKit.ensureInitialized();
  await initializeKurakoMediaSession();

  // Cap the decoded-image cache. Covers are downsampled at the widget level
  // (see CoverImage cacheWidth), but a hard byte ceiling is a cheap backstop so
  // browsing a large library / bouncing between detail pages can't let the
  // cache grow unbounded. 96MB comfortably holds a screenful of downsampled
  // covers while evicting the long tail.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 << 20;

  await RustLib.init();
  if (AndroidMediaStoreStorage.supported) {
    try {
      await AndroidMediaStoreStorage().cleanupPending();
    } catch (_) {
      // A failed cleanup must not block startup; entries stay hidden while
      // pending and a later launch retries the cleanup.
    }
  }

  // Desktop: drop the native OS title bar and manage the window ourselves
  // (custom drag region + window buttons drawn in-app). See widgets/
  // window_caption.dart. Android/iOS skip this entirely.
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  if (isDesktop) {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      size: Platform.isLinux ? const Size(1440, 900) : const Size(1280, 800),
      minimumSize: Platform.isLinux
          ? const Size(960, 640)
          : const Size(800, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      // macOS-only: window_manager's Windows plugin ignores this flag
      // entirely, so it does nothing there. On macOS it hides the native
      // traffic-light buttons in favor of our own WindowButtons.
      windowButtonVisibility: false,
      title: 'Kurako',
    );
    // Show only once ready to avoid a flash of the un-styled native frame.
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Open the SQLite database in the app data directory. On Windows this lives
  // under Documents/Kurako so it survives installer updates and portable
  // relocations; other platforms use the sandboxed app-support dir.
  final dir = await _dataDir();
  final dbPath = p.join(dir.path, 'anime_library.db');
  await rust.initDb(dbPath: dbPath);
  appDataDirPath = dir.path;
  defaultDownloadDirPath = await _defaultDownloadDir(dir);

  // Restore the saved Bangumi token, if any.
  final prefs = await SharedPreferences.getInstance();
  // The custom download folder needs its security scope while Rust scans it
  // for records; without it the scan silently finds nothing and the app
  // re-downloads episodes it already has.
  var downloadScope = <String>[];
  final savedDownloadDir = prefs.getString('download_dir') ?? '';
  if (Platform.isMacOS && savedDownloadDir.isNotEmpty) {
    try {
      final scope = await SecurityScope.access(savedDownloadDir);
      downloadScope = [scope.scopePath];
    } catch (_) {
      // Folder moved/unmounted: keep the preference, it can be re-picked.
    }
  }
  await rust.setDownloadDirectory(
    downloadDir: effectiveDownloadDir(savedDownloadDir),
  );
  for (final scopePath in downloadScope) {
    await SecurityScope.release(scopePath);
  }
  final token = prefs.getString('bangumi_token');
  if (token != null && token.isNotEmpty) {
    rust.setBangumiToken(token: token);
  }

  // Cache the decode mode so the player can configure its VideoController
  // synchronously (the configuration is fixed at construction time).
  decodeModeStartupValue = prefs.getString('decode_mode') ?? 'auto';

  rust.setBangumiMirror(enabled: false);
  BangumiMirrorService.instance.bindBackend(
    BangumiMirrorBackend(
      configure:
          ({required apiCookie, required imageCookie, required userAgent}) =>
              mirror.configureBangumiMirrorVerification(
                apiCookie: apiCookie,
                imageCookie: imageCookie,
                userAgent: userAgent,
              ),
      probeApi: mirror.probeBangumiMirror,
      probeImage: (imageUrl) =>
          mirror.probeBangumiMirrorImage(imageUrl: imageUrl),
      setEnabled: (enabled) async => rust.setBangumiMirror(enabled: enabled),
      clear: () async => mirror.clearBangumiMirrorVerification(),
    ),
  );

  // Restore SMB credentials so network-share folders work without re-entering
  // the password (connection is opened lazily per operation).
  (await SmbCredentials.load()).pushToRust();
  await (await WebDavCredentials.load()).pushToRust();

  // Route cover-image downloads through the same system proxy the Rust HTTP
  // client uses (Bangumi's CDN is DNS-poisoned in mainland China). The
  // override is installed even when no proxy is detected: it also guarantees
  // that loopback requests never pick up an environment proxy variable, which
  // would otherwise intercept the local media server's pre-flight probe.
  final proxy = await rust.systemProxy();
  HttpOverrides.global = ProxyHttpOverrides(proxyHostPort(proxy));

  runApp(const ProviderScope(child: AnimeBdApp()));
}

void _registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Kurako',
    ], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'Kurako third-party notices',
    ], await rootBundle.loadString('THIRD_PARTY_NOTICES.txt'));
    yield LicenseEntryWithLineBreaks([
      'LXGW WenKai GB Screen',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
}

/// The directory holding the app's SQLite DB and caches.
///
/// On Windows we use `Documents/Kurako` so data survives installer updates
/// and moving the portable folder. Other platforms keep their sandboxed
/// app-support directory.
Future<Directory> _dataDir() async {
  if (!Platform.isWindows) {
    return getApplicationSupportDirectory();
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'Kurako'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Where downloads go by default.
///
/// Desktop platforms use the system's own video/movie folder so downloads land
/// where users expect them and are reachable from Finder/Explorer/file
/// managers. If that folder cannot be created (permissions, read-only volume)
/// we fall back to the app container, which always works. iOS keeps its
/// Files-visible Documents folder; Android is handled by the SAF flow.
Future<String> _defaultDownloadDir(Directory dataDir) async {
  const folderName = 'Kurako Downloads';
  if (Platform.isIOS) {
    final documents = await getApplicationDocumentsDirectory();
    final downloads = Directory(p.join(documents.path, folderName));
    if (!await downloads.exists()) {
      await downloads.create(recursive: true);
    }
    return downloads.path;
  }
  if (Platform.isAndroid) return p.join(dataDir.path, 'downloads');
  final candidate = await _systemVideosDir();
  if (candidate != null) {
    try {
      final dir = Directory(p.join(candidate, folderName));
      if (!await dir.exists()) await dir.create(recursive: true);
      // Inside the sandbox $HOME points at the app container, whose Movies
      // entry is a symlink to the real one. Resolve it so the UI shows the
      // path the user actually sees in Finder.
      return await _realPath(dir.path);
    } catch (_) {
      // Fall through to the container directory below.
    }
  }
  return p.join(dataDir.path, 'downloads');
}

/// Resolve symlinks; the path itself is returned when it cannot be resolved.
Future<String> _realPath(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } catch (_) {
    return path;
  }
}

/// The platform's standard video folder, or null when it cannot be resolved.
Future<String?> _systemVideosDir() async {
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    return home == null ? null : p.join(home, 'Movies');
  }
  if (Platform.isWindows) {
    final profile = Platform.environment['USERPROFILE'];
    return profile == null ? null : p.join(profile, 'Videos');
  }
  if (Platform.isLinux) {
    final xdg = await _xdgUserDir('XDG_VIDEOS_DIR');
    if (xdg != null) return xdg;
    final home = Platform.environment['HOME'];
    return home == null ? null : p.join(home, 'Videos');
  }
  return null;
}

/// Resolve an XDG user directory (e.g. XDG_VIDEOS_DIR) honouring a localized
/// name such as `~/影片`. Only the standard config file is read; no process is
/// spawned and a malformed file simply falls back to the caller's default.
Future<String?> _xdgUserDir(String key) async {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final configHome =
      Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
  final file = File(p.join(configHome, 'user-dirs.dirs'));
  try {
    if (!await file.exists()) return null;
    final lines = await file.readAsLines();
    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('$key=')) continue;
      var value = trimmed.substring(key.length + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      value = value.replaceFirst(r'$HOME', home);
      if (!value.startsWith('/')) return null;
      return value;
    }
  } catch (_) {
    // Unreadable or malformed config: use the caller's fallback.
  }
  return null;
}
