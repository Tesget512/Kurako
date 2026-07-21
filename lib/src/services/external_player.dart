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
  // OS default association, detached so it never blocks the caller.
  if (Platform.isWindows) {
    // rundll32 opens the file with its registered handler without going through
    // cmd's `start` (whose argument quoting is fragile for paths with spaces/&).
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
