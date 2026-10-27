import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurako/src/state/home_preferences.dart';
import 'package:kurako/src/state/appearance_presets.dart';
import 'package:kurako/src/state/interface_preferences.dart';
import 'package:kurako/src/state/player_appearance.dart';
import 'package:kurako/src/services/configuration_backup.dart';
import 'package:kurako/src/pages/watching_home_page.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/state/watch_providers.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/rust/watch_history.dart';

void main() {
  test('resume uses latest exact eligible episode and excludes completed removed and downloaded rows', () async {
    final c = ProviderContainer(
      overrides: [
        animeListProvider.overrideWith(
          (ref) async => [
            for (var id = 1; id <= 5; id++)
              Anime(
                id: id,
                titleRaw: 'Fixture',
                hasNewFiles: false,
                collection: 3,
                matchConfidence: 'high',
                corrected: false,
                episodeCount: 2,
                watchedCount: 0,
                specialCount: 0,
              ),
          ],
        ),
        watchSummaryProvider.overrideWith(
          (ref) async => WatchStatistics(
            totalMs: 300,
            animeCount: 5,
            episodeCount: 6,
            days: [],
            episodes: [
              _entry(1, 1, 10),
              _entry(1, 2, 30),
              _entry(2, 3, 40),
              _entry(3, 4, 50, available: false),
              _entry(4, -5, 60),
              _entry(5, 6, 70),
            ],
          ),
        ),
        episodesProvider.overrideWith(
          (ref, id) async => [
            if (id == 1) _episode(1, 1),
            if (id == 1) _episode(1, 2),
            if (id == 2) _episode(2, 3, watched: true),
            if (id == 5) _episode(5, 6, fileName: 'replacement.mkv'),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    final subscription = c.listen(resumeItemsProvider, (_, _) {});
    addTearDown(subscription.close);
    final result = await c.read(resumeItemsProvider.future);
    expect(result.map((r) => r.episode.id), [2]);
  });

  test('preset validation rejects unknown fields duplicate names and navigation capture', () {
    for (final bad in [
      [
        {
          'name': 'bad',
          'values': {...appearanceDefaults, 'bangumi_token': 'fixture-only'},
        },
      ],
      [
        {'name': 'same', 'values': appearanceDefaults},
        {'name': 'same', 'values': appearanceDefaults},
      ],
      [
        {
          'name': 'bad',
          'values': {...appearanceDefaults, 'theme_seed_index': 999},
        },
      ],
      [
        {
          'name': 'bad',
          'values': {...appearanceDefaults, 'home_preferences': '{}'},
        },
      ],
    ]) {
      expect(validAppearancePresets(jsonEncode(bad)), isFalse);
    }
  });

  test(
    'legacy presets keep their stored font choice after default migration',
    () async {
      SharedPreferences.setMockInitialValues({
        appearancePresetsKey: jsonEncode([
          {'name': '旧预设', 'values': appearanceDefaults},
        ]),
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(appearancePresetsProvider.notifier).ready;
      expect(
        c.read(appearancePresetsProvider).single.values['use_system_font'],
        isFalse,
      );
      final current = await SharedPreferences.getInstance();
      await c.read(appearancePresetsProvider.notifier).save('新预设');
      expect(current.getString(appearancePresetsKey), contains('"新预设"'));
      expect(
        c.read(appearancePresetsProvider).last.values['use_system_font'],
        isTrue,
      );
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'applying presets reloads already active interface preferences',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final subscription = c.listen(interfacePreferencesProvider, (_, _) {});
      addTearDown(subscription.close);
      await c.read(interfacePreferencesProvider.notifier).ready;
      final presets = c.read(appearancePresetsProvider.notifier);
      await presets.save('默认');
      await c
          .read(interfacePreferencesProvider.notifier)
          .setPosterSize(PosterSize.large);
      await presets.apply('默认');
      await c.read(interfacePreferencesProvider.notifier).ready;
      expect(
        c.read(interfacePreferencesProvider).posterSize,
        PosterSize.standard,
      );
    },
  );

  test(
    'restore invalidation reloads home preferences and saved presets',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final homeSubscription = c.listen(homePreferencesProvider, (_, _) {});
      final presetsSubscription = c.listen(
        appearancePresetsProvider,
        (_, _) {},
      );
      addTearDown(homeSubscription.close);
      addTearDown(presetsSubscription.close);
      await c.read(homePreferencesProvider.notifier).ready;
      await c.read(appearancePresetsProvider.notifier).ready;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        homePreferencesKey,
        const HomePreferences(initial: AppDestination.home).encode(),
      );
      await prefs.setString(
        appearancePresetsKey,
        jsonEncode([
          {'name': '恢复的预设', 'values': appearanceDefaults},
        ]),
      );
      c.invalidate(homePreferencesProvider);
      c.invalidate(appearancePresetsProvider);
      await c.read(homePreferencesProvider.notifier).ready;
      await c.read(appearancePresetsProvider.notifier).ready;
      expect(c.read(homePreferencesProvider).initial, AppDestination.home);
      expect(c.read(appearancePresetsProvider).single.name, '恢复的预设');
    },
  );

  test('applying presets refreshes active player appearance', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final subscription = c.listen(playerAppearanceProvider, (_, _) {});
    addTearDown(subscription.close);
    await c.read(playerAppearanceProvider.notifier).ready;
    final presets = c.read(appearancePresetsProvider.notifier);
    await presets.save('默认');
    await (await SharedPreferences.getInstance()).setInt(
      playerBrightnessColorKey,
      0xFF112233,
    );
    await presets.apply('默认');
    await c.read(playerAppearanceProvider.notifier).ready;
    expect(
      c.read(playerAppearanceProvider).brightness.toARGB32(),
      defaultPlayerBrightnessColor,
    );
  });

  test(
    'disabling home persists a valid startup destination across restart',
    () async {
      final c = ProviderContainer();
      final n = c.read(homePreferencesProvider.notifier);
      await n.setInitial(AppDestination.home);
      await n.setEnabled(false);
      c.dispose();
      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      await restored.read(homePreferencesProvider.notifier).ready;
      expect(restored.read(homePreferencesProvider).enabled, isFalse);
      expect(
        restored.read(homePreferencesProvider).initial,
        AppDestination.library,
      );
    },
  );

  test('queued module edits retain order and visibility', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(homePreferencesProvider.notifier);
    await Future.wait([
      n.move(HomeModule.watching, -1),
      n.show(HomeModule.resume, false),
      n.show(HomeModule.watching, false),
    ]);
    final value = HomePreferences.decode(
      (await SharedPreferences.getInstance()).getString(homePreferencesKey)!,
    );
    expect(value.modules, [
      HomeModule.watching,
      HomeModule.resume,
      HomeModule.wish,
    ]);
    expect(value.hidden, {
      HomeModule.resume,
      HomeModule.watching,
      HomeModule.wish,
    });
    await n.show(HomeModule.wish, true);
    final saved = HomePreferences.decode(
      (await SharedPreferences.getInstance()).getString(homePreferencesKey)!,
    );
    expect(saved.hidden, isNot(contains(HomeModule.wish)));
    expect(saved.modules, value.modules);
    await n.reset();
    expect(c.read(homePreferencesProvider).hidden, {HomeModule.wish});
  });

  test(
    'malformed home config falls back while strict backup rejects it',
    () async {
      SharedPreferences.setMockInitialValues({homePreferencesKey: '{bad'});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(homePreferencesProvider.notifier).ready;
      expect(c.read(homePreferencesProvider).initial, AppDestination.library);
      await (await SharedPreferences.getInstance()).remove(homePreferencesKey);
      final root = jsonDecode(
        await ConfigurationBackupDocument.exportJson(),
      ) as Map<String, dynamic>;
      (root['settings'] as Map)[homePreferencesKey] = '{bad';
      expect(
        () => ConfigurationBackupDocument.parse(jsonEncode(root)),
        throwsFormatException,
      );
    },
  );

  test('preset lifecycle restores appearance without changing navigation or secrets', () async {
    SharedPreferences.setMockInitialValues({
      'theme_seed_index': 4,
      'interface_poster_size': 'large',
      'interface_posterRating': false,
      'home_preferences': 'untouched',
      'bangumi_token': 'fixture-only',
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(appearancePresetsProvider.notifier);
    await n.save('我的配色');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(appearancePresetsKey),
      isNot(contains('fixture-only')),
    );
    expect(
      prefs.getString(appearancePresetsKey),
      isNot(contains('home_preferences')),
    );
    await prefs.setInt('theme_seed_index', 1);
    await prefs.setString('interface_poster_size', 'compact');
    await n.apply('我的配色');
    expect(prefs.getInt('theme_seed_index'), 4);
    expect(prefs.getString('interface_poster_size'), 'large');
    expect(prefs.getString('home_preferences'), 'untouched');
    await c.read(interfacePreferencesProvider.notifier).ready;
    expect(c.read(interfacePreferencesProvider).posterSize, PosterSize.large);
    await n.rename('我的配色', '夜间');
    expect(c.read(appearancePresetsProvider).single.name, '夜间');
    await n.save('夜间', replace: true);
    await expectLater(n.save('夜间'), throwsFormatException);
    await expectLater(n.save('  '), throwsFormatException);
    await n.delete('夜间');
    expect(c.read(appearancePresetsProvider), isEmpty);
  });

  test(
    'v8 backup round trips presets and v7 retains local new settings',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(appearancePresetsProvider.notifier).save('默认');
      await c
          .read(homePreferencesProvider.notifier)
          .setInitial(AppDestination.collection);
      final source = await ConfigurationBackupDocument.exportJson();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(appearancePresetsKey);
      await ConfigurationBackupDocument.parse(source).apply();
      expect(prefs.getString(appearancePresetsKey), contains('默认'));
      final old = jsonDecode(source) as Map<String, dynamic>;
      old['schemaVersion'] = 7;
      (old['settings'] as Map).remove(homePreferencesKey);
      (old['settings'] as Map).remove(appearancePresetsKey);
      (old['settings'] as Map).remove('player_keyboard_shortcuts');
      await ConfigurationBackupDocument.parse(jsonEncode(old)).apply();
      expect(
        HomePreferences.decode(prefs.getString(homePreferencesKey)!).initial,
        AppDestination.collection,
      );
    },
  );
}

WatchEntry _entry(int anime, int episode, int time, {bool available = true}) =>
    WatchEntry(
      sessionId: 'fixture',
      mediaKey: 'fixture-$episode',
      animeId: anime,
      episodeId: episode,
      episodeNo: 1,
      animeTitle: 'Fixture',
      episodeTitle: 'Fixture',
      fileName: 'episode.mkv',
      startedMs: 0,
      lastWatchedMs: time,
      watchedMs: 10,
      available: available,
    );
Episode _episode(
  int anime,
  int id, {
  bool watched = false,
  String fileName = 'episode.mkv',
}) => Episode(
  id: id,
  animeId: anime,
  filePath: '/fixture/episode.mkv',
  fileName: fileName,
  episodeNo: id,
  watched: watched,
  lastPositionMs: 5000,
  durationMs: 10000,
  sourceType: 'local',
  isNewFile: false,
  isDownloaded: false,
);
