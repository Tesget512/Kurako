import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';
import 'ios_platform.dart';

/// The locator to hand an external player for [ep].
///
/// - A downloaded local copy is always preferred (instant, seekable).
/// - **Windows SMB (not downloaded):** hand a UNC path `\\host\share\path` and
///   let Windows' own SMB client serve it — the default video player opens it
///   exactly like a local file (no loopback proxy, no forced program choice).
///   This is why external SMB playback now behaves identically to local.
/// - **Android/iOS SMB (not downloaded):** hand a real
///   `smb://user:pass@host/path`
///   URI (see [_smbUrlWithCreds]) so the external player's *own* bundled SMB
///   client (VLC/MX Player both ship one, same as our Rust smb2 client) connects
///   directly — mirrors how VLC's own network browser opens SMB shares. This is
///   NOT the loopback proxy: our proxy runs inside our app's process, and
///   Android freezes a fully-backgrounded app's threads within seconds (the
///   "cached app freezer"), which happens the moment the external player takes
///   focus — the proxy stops responding right as the player tries to connect
///   ("无法播放位置 http://127.0.0.1:.../tN"). A direct smb:// URI has no such
///   dependency on our app staying alive.
/// - **macOS/Linux SMB (not downloaded):** fall back to the loopback proxy's
///   http:// URL (no universal UNC equivalent, unconfirmed whether their common
///   players accept smb:// via ACTION_VIEW-equivalent — untested).
Future<String> externalPlayerLocator(Episode ep) async {
  if (ep.sourceType != 'smb') return ep.filePath;
  final local = await rust.downloadedLocalPath(smbUri: ep.filePath);
  if (local != null) return local;
  if (Platform.isWindows) {
    return smbUncPath(ep.filePath);
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return _smbUrlWithCreds(ep.filePath);
  }
  return rust.smbPlayableUrl(smbUri: ep.filePath);
}

/// Inject the stored SMB credentials into an `smb://host:port/share/path` URI →
/// `smb://user:pass@host/share/path` (URL-encoded user/pass). Drops the :445
/// port most players don't expect. Falls back to the bare URI if unconfigured.
Future<String> _smbUrlWithCreds(String smbUri) async {
  final creds = await SmbCredentials.load();
  final rest = smbUri.replaceFirst('smb://', '');
  // rest = host[:port]/share/path...
  final slash = rest.indexOf('/');
  if (slash < 0) return smbUri;
  var host = rest.substring(0, slash);
  // Episode paths originate from SMB directory entries and are deliberately
  // kept as human-readable strings in the database.  `URL(string:)` on iOS
  // rejects their spaces, CJK characters and brackets, though VLC/Infuse do
  // register the smb scheme itself. Encode each component only at the handoff
  // boundary; preserve `/` as a path separator.
  final pathPart = rest
      .substring(slash)
      .split('/')
      .map(Uri.encodeComponent)
      .join('/');
  if (host.contains(':445')) host = host.replaceFirst(':445', '');
  if (creds.user.isEmpty) return 'smb://$host$pathPart';
  final u = Uri.encodeComponent(creds.user);
  final p = Uri.encodeComponent(creds.password);
  return 'smb://$u:$p@$host$pathPart';
}

/// Convert `smb://host[:port]/share/sub/file.mkv` → Windows UNC
/// `\\host\share\sub\file.mkv` (drop the port, `/` → `\`). Windows opens UNC
/// paths through its built-in SMB redirector, so any video player handles it
/// like a local file. Returns the input unchanged if it isn't an smb:// URI.
String smbUncPath(String smbUri) {
  final rest = smbUri.replaceFirst('smb://', '');
  final slash = rest.indexOf('/');
  if (slash < 0) return smbUri;
  var host = rest.substring(0, slash);
  final colon = host.indexOf(':');
  if (colon >= 0) host = host.substring(0, colon); // drop :445
  final pathPart = rest.substring(slash + 1).replaceAll('/', '\\');
  return '\\\\$host\\$pathPart';
}

/// Establish a Windows SMB session for the `\\host\share` root of [uncPath]
/// using the stored credentials, so the default player (or a configured one)
/// can read the file. Best-effort: `net use` fails harmlessly if the share is
/// already connected (error 1219) or needs no auth, so we ignore the result and
/// let playback proceed regardless. No-op when no username is stored (guest /
/// pre-authenticated share).
Future<void> ensureUncAuth(String uncPath) async {
  final creds = await SmbCredentials.load();
  if (creds.user.isEmpty) return;
  // uncPath = \\host\share\sub\file → share root = \\host\share
  final parts = uncPath.split('\\')..removeWhere((s) => s.isEmpty);
  if (parts.length < 2) return;
  final shareRoot = '\\\\${parts[0]}\\${parts[1]}';
  final args = <String>[
    'use',
    shareRoot,
    creds.password,
    '/user:${creds.user}',
  ];
  try {
    // Wait for completion (fast) so the session exists before the player opens
    // the file; swallow any error (already-connected / no-auth shares).
    await Process.run('net', args);
  } catch (_) {}
}

/// Launch a video in an external player.
///
/// - Desktop (Windows/macOS/Linux): [locator] is a filesystem path. Uses the
///   configured player executable, or the OS default file association.
/// - Android: [locator] is a content:// SAF URI. Fires an ACTION_VIEW intent so
///   the user's chosen player app opens it (with temporary read permission).
///   The desktop [playerPath] setting is ignored — Android picks the app itself.
Future<void> launchExternalPlayer(String playerPath, String locator) async {
  if (Platform.isIOS) {
    if (locator.startsWith('smb://')) {
      // iOS has no generic ACTION_VIEW chooser. Ask the OS to dispatch the
      // native SMB URI; Files, VLC and other installed players may register a
      // compatible handler and can then stream independently of KURAKO.
      if (!await IosPlatform.openExternalUrl(locator)) {
        throw Exception(
          '系统没有可处理 SMB 地址的播放器。请在文件 App 或 VLC 中确认该 SMB 地址可打开，或先下载到本地',
        );
      }
      return;
    }
    if (!await IosPlatform.shareVideo(locator)) {
      throw Exception('无法打开系统分享面板，请确认该视频仍可访问');
    }
    return;
  }
  if (Platform.isAndroid) {
    await _launchAndroidIntent(locator);
    return;
  }

  // A Windows UNC path (\\host\share\...) points at an authenticated share:
  // establish the session first so both a configured player and the default
  // association can read it, exactly like a local file.
  if (Platform.isWindows && locator.startsWith(r'\\')) {
    await ensureUncAuth(locator);
  }

  final path = playerPath.trim();
  if (path.isNotEmpty) {
    // Detached so the child owns no stdio pipes and the Dart side never waits on
    // it (piped mode could hang the UI if the player didn't drain stdout).
    await Process.start(path, [locator], mode: ProcessStartMode.detached);
    return;
  }
  // No configured player.
  if (Platform.isWindows) {
    // An http proxy URL (SMB stream) has no file association — opening it via
    // the shell lands in the default *browser* (the "web player" bug). SMB now
    // resolves to a UNC path on Windows, which HAS a normal file association, so
    // it opens in the default video player like any local file — no forced
    // program choice. Only the (macOS/Linux-only) proxy fallback stays http.
    if (locator.startsWith('http')) {
      throw Exception('未配置外置播放器。请在 设置 → 播放器 中选择播放器程序（SMB 流播放需要）');
    }
    await Process.start('rundll32', [
      'url.dll,FileProtocolHandler',
      locator,
    ], mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await Process.start('open', [locator], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [locator], mode: ProcessStartMode.detached);
  }
}

/// Show the Windows "Open with" dialog so the user can choose / set the default
/// program. `OpenAs_RunDLL` needs a real file, so we operate on a temp `.mp4`
/// (its content doesn't matter — we only want the media-player list and, if the
/// user ticks "always", the association that streamed playback will then use).
Future<void> _openWithChooser() async {
  final dir = await Directory.systemTemp.createTemp('abp_openas_');
  final sample = File('${dir.path}\\sample.mp4');
  try {
    await sample.writeAsBytes(const [0]);
  } catch (_) {}
  await Process.start('rundll32', [
    'shell32.dll,OpenAs_RunDLL',
    sample.path,
  ], mode: ProcessStartMode.detached);
}

/// Open the Windows "Open with" chooser so the user can (re)pick / set the
/// default program. Exposed for the settings "重选默认程序" action.
Future<void> openWindowsProgramChooser() async {
  if (!Platform.isWindows) return;
  await _openWithChooser();
}

/// Hand a content:// / smb:// / file URI to an external player via ACTION_VIEW.
/// Always sets an explicit `video/*` MIME — video players generally register a
/// scheme-agnostic `video/*` filter (matching local/content files) rather than
/// one per network scheme, so even though VLC has no `smb` intent-filter, an
/// explicit `video/*` type still matches its generic video-view filter for any
/// data scheme. Omitting the type (as this used to for smb://) leaves the
/// implicit type unresolved for schemes with no ContentResolver mapping, which
/// only matches scheme-specific filters — VLC has none for `smb`, hence the
/// old "No Activity found" error. The grant flag lets the receiving app read a
/// SAF document. Falls back to an explicit chooser if the direct intent finds
/// no default handler.
Future<void> _launchAndroidIntent(String uri) async {
  final intent = AndroidIntent(
    action: 'action_view',
    data: uri,
    type: 'video/*',
    flags: <int>[
      Flag.FLAG_ACTIVITY_NEW_TASK,
      Flag.FLAG_GRANT_READ_URI_PERMISSION,
    ],
  );
  // A raw smb:// URI (not-yet-downloaded SMB episode) only opens in a player
  // that registers its OWN intent-filter for the `smb` scheme — confirmed on a
  // real device that neither VLC nor MX Player do this for external
  // ACTION_VIEW (their SMB support is for browsing shares *within* the app,
  // not for another app handing them a smb:// link). Falling back to the OS's
  // own chooser in that case just shows an unhelpful, unbranded "没有应用可执行
  // 此操作" sheet — so check resolvability first and give a clear, actionable
  // message instead of ever inflicting that dead end on the user.
  if (uri.startsWith('smb://')) {
    final canResolve = await intent.canResolveActivity() ?? false;
    if (!canResolve) {
      throw Exception(
        '未找到支持 SMB 网络串流的播放器（如 VLC、MX Player）。请安装兼容的播放器，'
        '或先将该集下载到本地后再用外部播放器打开',
      );
    }
    await intent.launch();
    return;
  }
  try {
    await intent.launch();
  } catch (_) {
    // No default handler for this data/type — let the user pick an app.
    await intent.launchChooser('选择播放器');
  }
}

/// Reveal a local file in the OS file manager (desktop only — SMB/SAF sources
/// have no filesystem path to point at). Windows highlights the file itself;
/// macOS does the same via Finder; Linux has no universal "select" verb, so it
/// falls back to opening the containing folder.
Future<void> revealInFileManager(String path) async {
  if (Platform.isWindows) {
    // Must be two separate argv entries: explorer.exe's "/select," parsing
    // expects the switch bare and the path as its own (auto-quoted-if-needed)
    // token. Interpolating them into one string made Dart wrap the whole
    // "/select,<path>" blob in a single pair of quotes whenever the path had a
    // space — which explorer.exe doesn't recognize as the /select switch at
    // all, so it silently fell back to opening a plain Explorer window.
    await Process.start('explorer.exe', [
      '/select,',
      path,
    ], mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await Process.start('open', ['-R', path], mode: ProcessStartMode.detached);
  } else if (Platform.isLinux) {
    final dir = File(path).parent.path;
    await Process.start('xdg-open', [dir], mode: ProcessStartMode.detached);
  }
}

/// Force Android's "打开方式" chooser for a local/SAF file, even if the user
/// previously set a default app for this type — unlike the plain ACTION_VIEW
/// intent above (which silently reuses that default), `createChooser` always
/// prompts.
Future<void> chooseAndroidApp(String uri) async {
  if (!Platform.isAndroid) return;
  final intent = AndroidIntent(
    action: 'action_view',
    data: uri,
    type: 'video/*',
    flags: <int>[Flag.FLAG_GRANT_READ_URI_PERMISSION],
  );
  await intent.launchChooser('选择打开方式');
}
