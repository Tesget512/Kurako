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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  await RustLib.init();

  // Desktop: drop the native OS title bar and manage the window ourselves
  // (custom drag region + window buttons drawn in-app). See widgets/
  // window_caption.dart. Android/iOS skip this entirely.
  final isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  if (isDesktop) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(800, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'KURAKO',
    );
    // Show only once ready to avoid a flash of the un-styled native frame.
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Open the SQLite database in the app data directory. On Windows this lives
  // under Documents/AnimeBDPlayer so it survives installer updates and portable
  // relocations; other platforms use the sandboxed app-support dir.
  final dir = await _dataDir();
  final dbPath = p.join(dir.path, 'anime_library.db');
  await rust.initDb(dbPath: dbPath);
  appDataDirPath = dir.path;

  // Restore the saved Bangumi token, if any.
  final prefs = await SharedPreferences.getInstance();
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
/// On Windows we use `Documents/AnimeBDPlayer` so data survives installer
/// updates and moving the portable folder. An existing DB from the old
/// app-support location is migrated once. Other platforms keep their sandboxed
/// app-support directory.
Future<Directory> _dataDir() async {
  if (!Platform.isWindows) {
    return getApplicationSupportDirectory();
  }
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'AnimeBDPlayer'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  // One-time migration of an existing library DB from the old location.
  final newDb = File(p.join(dir.path, 'anime_library.db'));
  if (!await newDb.exists()) {
    final oldDir = await getApplicationSupportDirectory();
    for (final name in [
      'anime_library.db',
      'anime_library.db-wal',
      'anime_library.db-shm',
    ]) {
      final old = File(p.join(oldDir.path, name));
      if (await old.exists()) {
        try {
          await old.copy(p.join(dir.path, name));
        } catch (_) {}
      }
    }
  }
  return dir;
}
