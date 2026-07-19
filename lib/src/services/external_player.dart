import 'dart:io';

/// Launch a video file in an external player.
///
/// If [playerPath] is set, runs that executable with the file as its argument.
/// Otherwise falls back to the OS default handler for the file type.
///
/// Uses [ProcessStartMode.detached] so the child owns no stdio pipes and the
/// Dart side never waits on it. Previously the default (piped) mode could hang
/// the UI on some machines when the external player didn't drain/close stdout.
Future<void> launchExternalPlayer(String playerPath, String filePath) async {
  final path = playerPath.trim();
  if (path.isNotEmpty) {
    await Process.start(
      path,
      [filePath],
      mode: ProcessStartMode.detached,
    );
    return;
  }
  // OS default association, detached so it never blocks the caller.
  if (Platform.isWindows) {
    // rundll32 opens the file with its registered handler without going through
    // cmd's `start` (whose argument quoting is fragile for paths with spaces/&).
    await Process.start(
      'rundll32',
      ['url.dll,FileProtocolHandler', filePath],
      mode: ProcessStartMode.detached,
    );
  } else if (Platform.isMacOS) {
    await Process.start('open', [filePath], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [filePath],
        mode: ProcessStartMode.detached);
  }
}
