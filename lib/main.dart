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

  // Open the SQLite database in the app support directory.
  final dir = await getApplicationSupportDirectory();
  final dbPath = p.join(dir.path, 'anime_library.db');
  await rust.initDb(dbPath: dbPath);
  // Where Rust caches cover images pulled from SMB snapshots.
  rust.setCacheDir(path: dir.path);

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
