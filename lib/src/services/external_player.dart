import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';

/// The locator to hand an external player for [ep]. SMB files can't be passed
/// as raw smb:// strings (most players have no credentials for the share) —
/// use the downloaded local copy when one exists, else register the file on
/// the loopback proxy and pass its http:// URL. The proxy token is left
/// registered for the lifetime of the app (we can't know when the external
/// player finishes); tokens are tiny, so this doesn't accumulate meaningfully.
Future<String> externalPlayerLocator(Episode ep) async {
  if (ep.sourceType != 'smb') return ep.filePath;
  final local = await rust.downloadedLocalPath(smbUri: ep.filePath);
  if (local != null) return local;
  return rust.smbPlayableUrl(smbUri: ep.filePath);
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

/// Hand a content:// (or file) URI to an external player via ACTION_VIEW. The
/// grant flag lets the receiving app read the SAF document.
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
  await intent.launch();
}
