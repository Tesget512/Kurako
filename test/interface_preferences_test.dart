import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurako/src/state/interface_preferences.dart';
import 'package:kurako/src/services/configuration_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('immediate and concurrent edits survive provider recreation', () async {
    SharedPreferences.setMockInitialValues({'interface_posterRating': false});
    final container = ProviderContainer();
    final notifier = container.read(interfacePreferencesProvider.notifier);
    await Future.wait([
      notifier.setOption(InterfaceOption.posterProgress, false),
      notifier.setOption(InterfaceOption.searchExpanded, true),
      notifier.setPosterSize(PosterSize.large),
    ]);
    container.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(interfacePreferencesProvider.notifier).ready;
    final settings = restored.read(interfacePreferencesProvider);
    expect(settings.enabled(InterfaceOption.posterProgress), isFalse);
    expect(settings.enabled(InterfaceOption.posterRating), isFalse);
    expect(settings.enabled(InterfaceOption.searchExpanded), isTrue);
    expect(settings.posterSize, PosterSize.large);
  });

  test('backup round trips interface options and accepts old v6', () async {
    SharedPreferences.setMockInitialValues({
      'interface_posterProgress': false,
      'interface_poster_size': 'large',
    });
    final source = await ConfigurationBackupDocument.exportJson();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('interface_posterProgress', true);
    await ConfigurationBackupDocument.parse(source).apply();
    expect(prefs.getBool('interface_posterProgress'), isFalse);
    final old = jsonDecode(source) as Map<String, dynamic>;
    old['schemaVersion'] = 6;
    (old['settings'] as Map<String, dynamic>).removeWhere(
      (key, _) =>
          key.startsWith('interface_') ||
          key == 'player_keyboard_shortcuts' ||
          key == 'home_preferences' ||
          key == 'appearance_presets',
    );
    await ConfigurationBackupDocument.parse(jsonEncode(old)).apply();
    expect(prefs.getString('interface_poster_size'), 'large');
  });
}
