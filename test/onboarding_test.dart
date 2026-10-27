import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/onboarding_page.dart';
import 'package:kurako/src/services/scan_coordinator.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:kurako/src/ui/theme.dart';
import 'package:kurako/src/widgets/media_source_manager.dart';

void main() {
  test('only macOS onboarding mentions sandbox authorization', () {
    final mac = onboardingCopyFor(OnboardingPlatform.macos);
    expect(mac.intro, contains('macOS'));
    expect(mac.chooseFolderLabel, '选择文件夹并授权');

    for (final platform in [
      OnboardingPlatform.windows,
      OnboardingPlatform.linux,
      OnboardingPlatform.ios,
      OnboardingPlatform.android,
    ]) {
      final copy = onboardingCopyFor(platform);
      expect(copy.intro, isNot(contains('macOS')));
      expect(copy.savedMessage, isNot(contains('访问权限')));
    }
  });

  test('Android modern storage is fixed to Download/Kurako', () {
    final copy = onboardingCopyFor(OnboardingPlatform.android);
    expect(copy.locationDescription, 'Download/Kurako');
    expect(copy.chooseFolderLabel, isNull);
  });

  test('Android legacy storage keeps the private download directory', () {
    final copy = onboardingCopyFor(
      OnboardingPlatform.android,
      androidLegacy: true,
    );
    expect(copy.locationDescription, contains('应用私有'));
    expect(copy.chooseFolderLabel, isNull);
  });

  test('completed onboarding is not exposed while preferences load', () async {
    SharedPreferences.setMockInitialValues({'onboarding_completed_v1': true});
    final container = ProviderContainer(
      overrides: [
        onboardingCompletedProvider.overrideWith(
          OnboardingCompletedNotifier.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(onboardingCompletedProvider.notifier);
    expect(notifier.state, OnboardingStatus.loading);
    await notifier.ready;
    expect(notifier.state, OnboardingStatus.completed);
    container.dispose();
  });

  test('unset onboarding preference becomes required after loading', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        onboardingCompletedProvider.overrideWith(
          OnboardingCompletedNotifier.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(onboardingCompletedProvider.notifier);
    expect(notifier.state, OnboardingStatus.loading);
    await notifier.ready;
    expect(notifier.state, OnboardingStatus.required);
    container.dispose();
  });

  testWidgets('onboarding places media sources before download location', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadDirProvider.overrideWithBuild((ref, notifier) => ''),
          foldersProvider.overrideWith((ref) async => const []),
          libraryMutationBusyProvider.overrideWith(
            LibraryMutationBusyNotifier.new,
          ),
        ],
        child: MaterialApp(
          theme: buildKurakoTheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
            systemFont: true,
          ),
          home: const OnboardingPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MediaSourceOnboardingPanel), findsOneWidget);
    final sources = tester.getTopLeft(find.text('媒体来源').first).dy;
    final downloads = tester.getTopLeft(find.text('下载位置')).dy;
    expect(sources, lessThan(downloads));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
