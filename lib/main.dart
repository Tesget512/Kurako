import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'src/rust/frb_generated.dart';
import 'src/rust/api.dart' as rust;
import 'src/app.dart';
import 'src/state/providers.dart';
import 'src/services/proxy.dart';
import 'src/services/media_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initializeKurakoMediaSession();

  // Cap the decoded-image cache. Covers are downsampled at the widget level
  // (see CoverImage cacheWidth), but a hard byte ceiling is a cheap backstop so
  // browsing a large library / bouncing between detail pages can't let the
  // cache grow unbounded. 96MB comfortably holds a screenful of downsampled
  // covers while evicting the long tail.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 << 20;

  await RustLib.init();

  // Desktop: drop the native OS title bar and manage the window ourselves
  // (custom drag region + window buttons drawn in-app). See widgets/
  // window_caption.dart. Android/iOS skip this entirely.
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  if (isDesktop) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(800, 600),
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
  // under Documents/KURAKO so it survives installer updates and portable
  // relocations; other platforms use the sandboxed app-support dir.
  final dir = await _dataDir();
  final dbPath = p.join(dir.path, 'anime_library.db');
  await rust.initDb(dbPath: dbPath);
  appDataDirPath = dir.path;
  defaultDownloadDirPath = await _defaultDownloadDir(dir);

  // Restore the saved Bangumi token, if any.
  final prefs = await SharedPreferences.getInstance();
  await rust.setDownloadDirectory(
    downloadDir: effectiveDownloadDir(prefs.getString('download_dir') ?? ''),
  );
  final token = prefs.getString('bangumi_token');
  if (token != null && token.isNotEmpty) {
    rust.setBangumiToken(token: token);
  }

  // Cache the decode mode so the player can configure its VideoController
  // synchronously (the configuration is fixed at construction time).
  decodeModeStartupValue = prefs.getString('decode_mode') ?? 'auto';

  // Route Bangumi API through the China mirror by default (the official domain
  // is frequently blocked in mainland China). Pushed before any request runs.
  rust.setBangumiMirror(enabled: prefs.getBool('bangumi_mirror') ?? true);

  // Restore SMB credentials so network-share folders work without re-entering
  // the password (connection is opened lazily per operation).
  (await SmbCredentials.load()).pushToRust();
  await (await WebDavCredentials.load()).pushToRust();

  // Route cover-image downloads through the same system proxy the Rust HTTP
  // client uses (Bangumi's CDN is DNS-poisoned in mainland China).
  final proxy = await rust.systemProxy();
  final hostPort = proxyHostPort(proxy);
  if (hostPort != null) {
    HttpOverrides.global = ProxyHttpOverrides(hostPort);
  }

  runApp(const ProviderScope(child: AnimeBdApp()));
}

/// The directory holding the app's SQLite DB and caches.
///
/// On Windows we use `Documents/KURAKO` so data survives installer updates
/// and moving the portable folder. Other platforms keep their sandboxed
/// app-support directory.
Future<Directory> _dataDir() async {
  if (!Platform.isWindows) {
    return getApplicationSupportDirectory();
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'KURAKO'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// iOS downloads belong in the app's Documents container, not App Support:
/// with file sharing enabled this is visible in Files as KURAKO's own folder.
/// The database remains private in App Support.
Future<String> _defaultDownloadDir(Directory dataDir) async {
  if (!Platform.isIOS) return p.join(dataDir.path, 'downloads');
  final documents = await getApplicationDocumentsDirectory();
  final downloads = Directory(p.join(documents.path, 'KURAKO Downloads'));
  if (!await downloads.exists()) {
    await downloads.create(recursive: true);
  }
  return downloads.path;
}
