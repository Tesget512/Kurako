import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const keyboardPreferencesKey = 'player_keyboard_shortcuts';

enum PlayerCommand {
  playPause,
  seekBack,
  seekForward,
  volumeUp,
  volumeDown,
  mute,
  fullscreen,
  previous,
  next,
  screenshot,
  lock,
}

const playerCommandLabels = {
  PlayerCommand.playPause: '播放 / 暂停',
  PlayerCommand.seekBack: '快退 5 秒',
  PlayerCommand.seekForward: '快进 5 秒',
  PlayerCommand.volumeUp: '提高音量',
  PlayerCommand.volumeDown: '降低音量',
  PlayerCommand.mute: '静音 / 恢复音量',
  PlayerCommand.fullscreen: '切换全屏',
  PlayerCommand.previous: '上一集',
  PlayerCommand.next: '下一集',
  PlayerCommand.screenshot: '截取画面',
  PlayerCommand.lock: '锁定 / 解锁',
};

class PlayerKeyBinding {
  const PlayerKeyBinding(
    this.key, {
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });
  final LogicalKeyboardKey key;
  final bool control, alt, shift, meta;
  SingleActivator get activator => SingleActivator(
    key,
    control: control,
    alt: alt,
    shift: shift,
    meta: meta,
    includeRepeats: false,
  );
  String get identity => '${key.keyId}:$control:$alt:$shift:$meta';
  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Cmd / Win',
    switch (key) {
      LogicalKeyboardKey.space => 'Space',
      LogicalKeyboardKey.arrowLeft => '←',
      LogicalKeyboardKey.arrowRight => '→',
      LogicalKeyboardKey.arrowUp => '↑',
      LogicalKeyboardKey.arrowDown => '↓',
      _ => key.keyLabel,
    },
  ].join(' + ');
  Map<String, Object> toJson() => {
    'key': key.keyId,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };
  static PlayerKeyBinding fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 5 ||
        raw['key'] is! int ||
        ['control', 'alt', 'shift', 'meta'].any((k) => raw[k] is! bool)) {
      throw const FormatException('快捷键格式无效');
    }
    final key = LogicalKeyboardKey.findKeyByKeyId(raw['key'] as int);
    if (key == null) throw const FormatException('无法识别此按键');
    final binding = PlayerKeyBinding(
      key,
      control: raw['control'] as bool,
      alt: raw['alt'] as bool,
      shift: raw['shift'] as bool,
      meta: raw['meta'] as bool,
    );
    if (binding.reserved) throw const FormatException('此按键由系统或退出操作保留');
    return binding;
  }

  bool get reserved =>
      isModifierKey(key) ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.tab ||
      key.keyLabel.isEmpty ||
      [
        LogicalKeyboardKey.mediaPlay,
        LogicalKeyboardKey.mediaPause,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaTrackNext,
        LogicalKeyboardKey.mediaTrackPrevious,
      ].contains(key) ||
      (alt && key == LogicalKeyboardKey.f4) ||
      (meta &&
          [
            LogicalKeyboardKey.keyQ,
            LogicalKeyboardKey.keyW,
            LogicalKeyboardKey.space,
          ].contains(key));
}

bool isModifierKey(LogicalKeyboardKey key) => {
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
}.contains(key);

const defaultPlayerKeys = <PlayerCommand, PlayerKeyBinding?>{
  PlayerCommand.playPause: PlayerKeyBinding(LogicalKeyboardKey.space),
  PlayerCommand.seekBack: PlayerKeyBinding(LogicalKeyboardKey.arrowLeft),
  PlayerCommand.seekForward: PlayerKeyBinding(LogicalKeyboardKey.arrowRight),
  PlayerCommand.volumeUp: PlayerKeyBinding(LogicalKeyboardKey.arrowUp),
  PlayerCommand.volumeDown: PlayerKeyBinding(LogicalKeyboardKey.arrowDown),
  PlayerCommand.mute: PlayerKeyBinding(LogicalKeyboardKey.keyM),
  PlayerCommand.fullscreen: PlayerKeyBinding(LogicalKeyboardKey.keyF),
  PlayerCommand.previous: PlayerKeyBinding(
    LogicalKeyboardKey.keyP,
    shift: true,
  ),
  PlayerCommand.next: PlayerKeyBinding(LogicalKeyboardKey.keyN, shift: true),
  PlayerCommand.screenshot: PlayerKeyBinding(LogicalKeyboardKey.keyS),
  PlayerCommand.lock: PlayerKeyBinding(LogicalKeyboardKey.keyK),
};

class KeyboardPreferences {
  KeyboardPreferences([
    Map<PlayerCommand, PlayerKeyBinding?> overrides = const {},
  ]) : bindings = Map.unmodifiable({...defaultPlayerKeys, ...overrides});
  final Map<PlayerCommand, PlayerKeyBinding?> bindings;
  String encode() => jsonEncode({
    for (final e in bindings.entries) e.key.name: e.value?.toJson(),
  });
  void validate() {
    final seen = <String>{};
    for (final e in bindings.entries) {
      if (e.value == null) continue;
      if (e.value!.reserved) throw const FormatException('此按键由系统或退出操作保留');
      if (!seen.add(e.value!.identity)) throw const FormatException('快捷键不能重复');
    }
  }

  static KeyboardPreferences decode(String source) {
    final raw = jsonDecode(source);
    if (raw is! Map ||
        raw.keys.any((k) => !PlayerCommand.values.any((a) => a.name == k))) {
      throw const FormatException('快捷键配置无效');
    }
    final result = KeyboardPreferences({
      for (final e in raw.entries)
        PlayerCommand.values.byName(e.key as String): e.value == null
            ? null
            : PlayerKeyBinding.fromJson(e.value),
    });
    result.validate();
    return result;
  }

  KeyboardPreferences change(PlayerCommand command, PlayerKeyBinding? binding) {
    if (binding != null) {
      for (final e in bindings.entries) {
        if (e.key != command && e.value?.identity == binding.identity) {
          throw FormatException('已用于“${playerCommandLabels[e.key]}”');
        }
      }
    }
    final result = KeyboardPreferences({...bindings, command: binding});
    result.validate();
    return result;
  }
}

bool validKeyboardPreferences(Object value) {
  if (value is! String || value.length > 16384) return false;
  try {
    KeyboardPreferences.decode(value);
    return true;
  } catch (_) {
    return false;
  }
}

final keyboardPreferencesProvider =
    NotifierProvider<KeyboardPreferencesNotifier, KeyboardPreferences>(
      KeyboardPreferencesNotifier.new,
    );

class KeyboardPreferencesNotifier extends Notifier<KeyboardPreferences> {
  late Future<void> ready;
  Future<void> _writes = Future.value();
  @override
  KeyboardPreferences build() {
    ready = _load();
    return KeyboardPreferences();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.get(keyboardPreferencesKey);
    if (ref.mounted && raw is String && validKeyboardPreferences(raw)) {
      state = KeyboardPreferences.decode(raw);
    }
  }

  Future<void> _update(
    KeyboardPreferences Function(KeyboardPreferences) transform,
  ) {
    final operation = _writes.then((_) async {
      await ready;
      if (!ref.mounted) return;
      final next = transform(state);
      if (!await (await SharedPreferences.getInstance()).setString(
        keyboardPreferencesKey,
        next.encode(),
      )) {
        throw StateError('快捷键保存失败');
      }
      if (ref.mounted) state = next;
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setBinding(PlayerCommand command, PlayerKeyBinding? binding) =>
      _update((s) => s.change(command, binding));
  Future<void> reset() => _update((_) => KeyboardPreferences());
}
