import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/rust/frb_generated.dart';
import 'src/rust/api.dart' as rust;
import 'src/app.dart';
import 'src/state/providers.dart';
import 'src/services/proxy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  await RustLib.init();

  // Open the SQLite database in the app data directory. On Windows this lives
  // under Documents/AnimeBDPlayer so it survives installer updates and portable
  // relocations; other platforms use the sandboxed app-support dir.
  final dir = await _dataDir();
  final dbPath = p.join(dir.path, 'anime_library.db');
  await rust.initDb(dbPath: dbPath);

  // Restore the saved Bangumi token, if any.
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('bangumi_token');
  if (token != null && token.isNotEmpty) {
    rust.setBangumiToken(token: token);
  }

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
