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

  test('episode naming defaults to release info and persists', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(interfacePreferencesProvider.notifier);
    await notifier.ready;
    expect(
      container.read(interfacePreferencesProvider).episodeNaming,
      EpisodeNaming.releaseInfo,
    );
    await notifier.setEpisodeNaming(EpisodeNaming.fileName);
    // Other settings written afterwards must not reset it.
    await notifier.setPosterSize(PosterSize.large);
    await notifier.setOption(InterfaceOption.posterRating, false);
    expect(
      container.read(interfacePreferencesProvider).episodeNaming,
      EpisodeNaming.fileName,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(episodeNamingKey), 'fileName');
    expect(EpisodeNaming.parse('garbage'), EpisodeNaming.releaseInfo);
    expect(EpisodeNaming.parse(null), EpisodeNaming.releaseInfo);
  });

  test(
    'backup carries episode naming; v9 files without it still import',
    () async {
      SharedPreferences.setMockInitialValues({episodeNamingKey: 'fileName'});
      final source = await ConfigurationBackupDocument.exportJson();
      final root = jsonDecode(source) as Map<String, dynamic>;
      expect(root['schemaVersion'], 10);
      expect(
        (root['settings'] as Map<String, dynamic>)[episodeNamingKey],
        'fileName',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(episodeNamingKey, 'releaseInfo');
      await ConfigurationBackupDocument.parse(source).apply();
      expect(prefs.getString(episodeNamingKey), 'fileName');

      final v9 = jsonDecode(source) as Map<String, dynamic>;
      v9['schemaVersion'] = 9;
      (v9['settings'] as Map<String, dynamic>).remove(episodeNamingKey);
      await prefs.setString(episodeNamingKey, 'releaseInfo');
      await ConfigurationBackupDocument.parse(jsonEncode(v9)).apply();
      // Not part of a v9 file, so the current choice is left alone.
      expect(prefs.getString(episodeNamingKey), 'releaseInfo');

      final bad = jsonDecode(source) as Map<String, dynamic>;
      (bad['settings'] as Map<String, dynamic>)[episodeNamingKey] = 'nonsense';
      expect(
        () => ConfigurationBackupDocument.parse(jsonEncode(bad)),
        throwsFormatException,
      );
    },
  );
}
