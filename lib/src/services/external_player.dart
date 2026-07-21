import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../state/providers.dart';

/// The locator to hand an external player for [ep].
///
/// - A downloaded local copy is always preferred (instant, seekable).
/// - **Android SMB (not downloaded):** the loopback proxy is unreachable from
///   another app's sandbox (each app has its own 127.0.0.1), so we hand the
///   player a real `smb://user:pass@host/share/path` URL, which VLC / MX Player
///   open natively.
/// - **Desktop SMB (not downloaded):** the loopback proxy works same-machine, so
///   use its http:// URL.
Future<String> externalPlayerLocator(Episode ep) async {
  if (ep.sourceType != 'smb') return ep.filePath;
  final local = await rust.downloadedLocalPath(smbUri: ep.filePath);
  if (local != null) return local;
  if (Platform.isAndroid) {
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
  final pathPart = rest.substring(slash); // leading '/'
  if (host.contains(':445')) host = host.replaceFirst(':445', '');
  if (creds.user.isEmpty) return 'smb://$host$pathPart';
  final u = Uri.encodeComponent(creds.user);
  final p = Uri.encodeComponent(creds.password);
  return 'smb://$u:$p@$host$pathPart';
}

/// Launch a video in an external player.
///
/// - Desktop (Windows/macOS/Linux): [locator] is a filesystem path. Uses the
///   configured player executable, or the OS default file association.
/// - Android: [locator] is a content:// SAF URI. Fires an ACTION_VIEW intent so
///   the user's chosen player app opens it (with temporary read permission).
///   The desktop [playerPath] setting is ignored — Android picks the app itself.
Future<void> launchExternalPlayer(String playerPath, String locator) async {
  if (Platform.isAndroid) {
    await _launchAndroidIntent(locator);
    return;
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
    // the shell lands in the default *browser* (the "web player" bug), and the
    // old .m3u wrapper could get stuck on a wrong association. Without a
    // configured player there's no reliable target, so tell the user to pick
    // one (the settings row next to the external-player toggle).
    if (locator.startsWith('http')) {
      throw Exception('未配置外置播放器。请在 设置 → 播放器 中选择播放器程序（SMB 流播放需要）');
    }
    await Process.start(
      'rundll32',
      ['url.dll,FileProtocolHandler', locator],
      mode: ProcessStartMode.detached,
    );
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
  await Process.start(
    'rundll32',
    ['shell32.dll,OpenAs_RunDLL', sample.path],
    mode: ProcessStartMode.detached,
  );
}

/// Open the Windows "Open with" chooser so the user can (re)pick / set the
/// default program. Exposed for the settings "重选默认程序" action.
Future<void> openWindowsProgramChooser() async {
  if (!Platform.isWindows) return;
  await _openWithChooser();
}

/// Hand a content:// / smb:// / file URI to an external player via ACTION_VIEW.
/// The grant flag lets the receiving app read a SAF document; for smb:// we omit
/// the video/* MIME so an SMB-capable player (VLC/MX) claims the scheme itself.
Future<void> _launchAndroidIntent(String uri) async {
  final isSmb = uri.startsWith('smb://');
  final intent = AndroidIntent(
    action: 'action_view',
    data: uri,
    type: isSmb ? null : 'video/*',
    flags: <int>[
      Flag.FLAG_ACTIVITY_NEW_TASK,
      Flag.FLAG_GRANT_READ_URI_PERMISSION,
    ],
  );
  await intent.launch();
}
