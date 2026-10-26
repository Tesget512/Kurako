import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interface_preferences.dart';
import 'player_appearance.dart';
import 'providers.dart';

const appearancePresetsKey = 'appearance_presets';
const appearanceDefaults = <String, Object>{
  'theme_seed_index': 0,
  'theme_follow_system': true,
  'theme_mode': 'system',
  'interface_poster_size': 'standard',
  'interface_searchExpanded': false,
  'interface_posterProgress': true,
  'interface_posterRating': true,
  'interface_posterBadge': true,
  'interface_playerSideTools': true,
  'ui_scale_percent': 100,
  'use_system_font': false,
  playerBrightnessColorKey: defaultPlayerBrightnessColor,
  playerVolumeColorKey: defaultPlayerVolumeColor,
};

bool _validValue(String key, Object? value) {
  if (appearanceDefaults[key] is bool) return value is bool;
  return switch (key) {
    'theme_seed_index' =>
      value is int && value >= 0 && value < kSeedPalette.length,
    'ui_scale_percent' => value is int && value >= 75 && value <= 150,
    'theme_mode' => ['system', 'light', 'dark'].contains(value),
    'interface_poster_size' => ['compact', 'standard', 'large'].contains(value),
    playerBrightnessColorKey || playerVolumeColorKey =>
      value is int && value >= 0xFF000000 && value <= 0xFFFFFFFF,
    _ => false,
  };
}

class AppearancePreset {
  const AppearancePreset(this.name, this.values);
  final String name;
  final Map<String, Object> values;
  Map<String, Object> toJson() => {'name': name, 'values': values};
}

List<AppearancePreset> decodeAppearancePresets(String raw) {
  if (raw.length > 65536) throw const FormatException('外观预设过大');
  final Object? json = jsonDecode(raw);
  if (json is! List || json.length > 20) {
    throw const FormatException('外观预设格式无效');
  }
  final names = <String>{};
  return List.unmodifiable(
    json.map((entry) {
      if (entry is! Map ||
          entry.length != 2 ||
          entry['name'] is! String ||
          entry['values'] is! Map) {
        throw const FormatException('外观预设格式无效');
      }
      final name = entry['name'] as String;
      final values = entry['values'] as Map;
      if (name.trim() != name ||
          name.isEmpty ||
          name.length > 40 ||
          !names.add(name) ||
          values.length != appearanceDefaults.length ||
          values.entries.any(
            (e) => e.key is! String || !_validValue(e.key as String, e.value),
          )) {
        throw const FormatException('外观预设包含无效内容');
      }
      return AppearancePreset(
        name,
        Map.unmodifiable(values.cast<String, Object>()),
      );
    }),
  );
}

bool validAppearancePresets(Object value) {
  if (value is! String) return false;
  try {
    decodeAppearancePresets(value);
    return true;
  } catch (_) {
    return false;
  }
}

final appearancePresetsProvider =
    NotifierProvider<AppearancePresetsNotifier, List<AppearancePreset>>(
      AppearancePresetsNotifier.new,
    );

class AppearancePresetsNotifier extends Notifier<List<AppearancePreset>> {
  late Future<void> ready;
  Future<void> _writes = Future.value();
  @override
  List<AppearancePreset> build() {
    ready = _load();
    return const [];
  }

  Future<void> _load() async {
    final raw = (await SharedPreferences.getInstance()).get(
      appearancePresetsKey,
    );
    final values = raw is String && validAppearancePresets(raw)
        ? decodeAppearancePresets(raw)
        : <AppearancePreset>[];
    if (ref.mounted) state = values;
  }

  Future<void> _queue(Future<void> Function(SharedPreferences) task) {
    final operation = _writes.then((_) async {
      await ready;
      if (ref.mounted) await task(await SharedPreferences.getInstance());
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _persist(
    SharedPreferences prefs,
    List<AppearancePreset> values,
  ) async {
    final raw = jsonEncode(values.map((p) => p.toJson()).toList());
    decodeAppearancePresets(raw);
    if (!await prefs.setString(appearancePresetsKey, raw)) {
      throw StateError('预设保存失败');
    }
    if (ref.mounted) state = List.unmodifiable(values);
  }

  Future<void> save(String name, {bool replace = false}) =>
      _queue((prefs) async {
        name = name.trim();
        final index = state.indexWhere((p) => p.name == name);
        if (name.isEmpty || name.length > 40) {
          throw const FormatException('名称需为 1–40 个字符');
        }
        if (index >= 0 && !replace) throw const FormatException('已存在同名预设');
        final values = <String, Object>{
          for (final e in appearanceDefaults.entries)
            e.key: _validValue(e.key, prefs.get(e.key))
                ? prefs.get(e.key)!
                : e.value,
        };
        final items = [...state];
        final preset = AppearancePreset(name, values);
        if (index < 0) {
          items.add(preset);
        } else {
          items[index] = preset;
        }
        await _persist(prefs, items);
      });
  Future<void> rename(String name, String next) => _queue((prefs) async {
    next = next.trim();
    await _persist(prefs, [
      for (final p in state)
        p.name == name ? AppearancePreset(next, p.values) : p,
    ]);
  });
  Future<void> delete(String name) => _queue(
    (prefs) => _persist(prefs, state.where((p) => p.name != name).toList()),
  );
  Future<void> apply(String name) => _queue(
    (prefs) => _apply(prefs, state.firstWhere((p) => p.name == name).values),
  );
  Future<void> resetAppearance() =>
      _queue((prefs) => _apply(prefs, appearanceDefaults));
  Future<void> _apply(
    SharedPreferences prefs,
    Map<String, Object> values,
  ) async {
    final before = {for (final key in values.keys) key: prefs.get(key)};
    Future<void> write(String key, Object value) async {
      final ok = switch (value) {
        bool v => await prefs.setBool(key, v),
        int v => await prefs.setInt(key, v),
        String v => await prefs.setString(key, v),
        _ => false,
      };
      if (!ok) throw StateError('外观配置保存失败');
    }

    try {
      for (final entry in values.entries) {
        await write(entry.key, entry.value);
      }
    } catch (_) {
      for (final entry in before.entries) {
        if (entry.value == null) {
          await prefs.remove(entry.key);
        } else {
          await write(entry.key, entry.value!);
        }
      }
      rethrow;
    }
    if (!ref.mounted) return;
    ref.invalidate(themeProvider);
    ref.invalidate(interfacePreferencesProvider);
    ref.invalidate(playerAppearanceProvider);
    ref.invalidate(uiScaleProvider);
    ref.invalidate(useSystemFontProvider);
  }
}
