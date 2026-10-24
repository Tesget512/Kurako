import 'package:flutter/services.dart';

/// Narrow macOS bridge for selecting an application bundle. `file_picker`'s
/// extension filter treats `.app` packages as directories, so the native
/// NSOpenPanel uses UTType.applicationBundle and validates the executable.
class MacPlayerPicker {
  static const MethodChannel _defaultChannel = MethodChannel(
    'com.tesget.kurako/player_picker',
  );

  final MethodChannel channel;

  MacPlayerPicker({MethodChannel? channel})
    : channel = channel ?? _defaultChannel;

  Future<String?> pickApplication() =>
      channel.invokeMethod<String>('pickApplication');
}
