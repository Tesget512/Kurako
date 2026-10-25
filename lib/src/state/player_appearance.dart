import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const playerBrightnessColorKey = 'player_brightness_color';
const playerVolumeColorKey = 'player_volume_color';
const defaultPlayerBrightnessColor = 0xFFFFD54F;
const defaultPlayerVolumeColor = 0xFF80CBC4;

class PlayerAppearance {
  final Color brightness;
  final Color volume;
  const PlayerAppearance({
    this.brightness = const Color(defaultPlayerBrightnessColor),
    this.volume = const Color(defaultPlayerVolumeColor),
  });
}

final playerAppearanceProvider =
    NotifierProvider<PlayerAppearanceNotifier, PlayerAppearance>(
      PlayerAppearanceNotifier.new,
    );

class PlayerAppearanceNotifier extends Notifier<PlayerAppearance> {
  @override
  PlayerAppearance build() {
    ready = _load();
    return const PlayerAppearance();
  }

  late final Future<void> ready;
  Future<void> _writes = Future<void>.value();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    Color read(String key, int fallback) {
      final value = prefs.getInt(key);
      return Color(
        value != null && value >= 0xFF000000 && value <= 0xFFFFFFFF
            ? value
            : fallback,
      );
    }

    state = PlayerAppearance(
      brightness: read(playerBrightnessColorKey, defaultPlayerBrightnessColor),
      volume: read(playerVolumeColorKey, defaultPlayerVolumeColor),
    );
  }

  Future<void> setColor({required bool brightness, required Color color}) {
    final write = _writes.then((_) async {
      await ready;
      final opaque = color.withAlpha(255);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        brightness ? playerBrightnessColorKey : playerVolumeColorKey,
        opaque.toARGB32(),
      );
      if (!ref.mounted) return;
      state = PlayerAppearance(
        brightness: brightness ? opaque : state.brightness,
        volume: brightness ? state.volume : opaque,
      );
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
