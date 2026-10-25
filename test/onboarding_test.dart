import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurako/src/pages/onboarding_page.dart';
import 'package:kurako/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}
