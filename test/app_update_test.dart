import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/pages/about_page.dart';
import 'package:kurako/src/services/app_update.dart';
import 'package:kurako/src/state/update_provider.dart';
import 'package:kurako/src/widgets/update_banner.dart';
import 'package:package_info_plus/package_info_plus.dart';

AppUpdateRelease release([String tag = 'v1.2.0']) => AppUpdateRelease(
  tagName: tag,
  htmlUrl: 'https://github.com/Tesget512/Kurako/releases/tag/$tag',
  name: 'Kurako $tag',
);

AppUpdateRelease releaseWithAssets(List<AppUpdateAsset> assets) =>
    AppUpdateRelease(
      tagName: 'v1.2.0',
      htmlUrl: 'https://github.com/Tesget512/Kurako/releases/tag/v1.2.0',
      name: 'Kurako v1.2.0',
      assets: assets,
    );

/// A release asset under the version this project actually publishes, using
/// the real download URL shape.
AppUpdateAsset asset(String name, {String? url}) => AppUpdateAsset(
  name: name,
  size: 52 * 1024 * 1024,
  url:
      url ??
      'https://github.com/Tesget512/Kurako/releases/download/v1.2.0/$name',
);

AppUpdateService service({
  Future<AppUpdateRelease?> Function()? fetch,
  String installed = '1.0.2',
  Future<bool> Function(Uri)? open,
}) => AppUpdateService(
  fetchLatestRelease: fetch ?? () async => release(),
  readInstalledVersion: () async => installed,
  openUrl: open,
);

void main() {
  test('asset URLs accept only this project release download', () {
    final release = releaseWithAssets([
      asset('Kurako-Android-arm64-v8a-1.2.0-release.apk'),
    ]);
    final good = asset('Kurako-Android-arm64-v8a-1.2.0-release.apk');
    expect(isProjectAssetUrl(release, good), isTrue);
    // A digest is optional, but a malformed one is not accepted.
    expect(
      isProjectAssetUrl(
        release,
        AppUpdateAsset(
          name: good.name,
          size: good.size,
          url: good.url,
          digest: 'sha256:${'a' * 64}',
        ),
      ),
      isTrue,
    );

    for (final bad in [
      // wrong host / scheme / credentials / port / query / fragment
      asset(good.name, url: 'https://example.com/${good.name}'),
      asset(
        good.name,
        url:
            'http://github.com/Tesget512/Kurako/releases/download/v1.2.0/${good.name}',
      ),
      asset(
        good.name,
        url:
            'https://user@github.com/Tesget512/Kurako/releases/download/v1.2.0/${good.name}',
      ),
      asset(
        good.name,
        url:
            'https://github.com:443/Tesget512/Kurako/releases/download/v1.2.0/${good.name}',
      ),
      asset(good.name, url: '${good.url}?x=1'),
      asset(good.name, url: '${good.url}#x'),
      // another repository or a tag page rather than a download
      asset(
        good.name,
        url:
            'https://github.com/other/Kurako/releases/download/v1.2.0/${good.name}',
      ),
      asset(
        good.name,
        url: 'https://github.com/Tesget512/Kurako/releases/tag/v1.2.0',
      ),
      // tag mismatch, name mismatch, non-Kurako name, blank name
      asset(
        good.name,
        url:
            'https://github.com/Tesget512/Kurako/releases/download/v9.9.9/${good.name}',
      ),
      asset(
        'Kurako-Android-arm64-v8a-1.2.0-release.apk',
        url: good.url.replaceAll('arm64-v8a', 'x86_64'),
      ),
      asset(good.name, url: good.url.replaceAll('Kurako-', 'Malware-')),
      asset(good.name, url: good.url.replaceAll(good.name, 'notes.txt')),
    ]) {
      expect(isProjectAssetUrl(release, bad), isFalse, reason: bad.url);
    }

    // A malformed digest and an implausible size are rejected.
    expect(
      isProjectAssetUrl(
        release,
        AppUpdateAsset(
          name: good.name,
          size: good.size,
          url: good.url,
          digest: 'sha256:xyz',
        ),
      ),
      isFalse,
    );
    expect(
      isProjectAssetUrl(
        release,
        AppUpdateAsset(name: good.name, size: 0, url: good.url),
      ),
      isFalse,
    );
    expect(
      isProjectAssetUrl(
        release,
        AppUpdateAsset(
          name: good.name,
          size: 5 * 1024 * 1024 * 1024,
          url: good.url,
        ),
      ),
      isFalse,
    );
  });

  test('compatible assets are selected per platform and architecture', () {
    final release = releaseWithAssets([
      asset('Kurako-Android-armeabi-v7a-1.2.0-release.apk'),
      asset('Kurako-Android-arm64-v8a-1.2.0-release.apk'),
      asset('Kurako-Android-x86_64-1.2.0-release.apk'),
      asset('Kurako-iOS-1.2.0-no_sign-release.ipa'),
      asset('Kurako-macOS-1.2.0-universal-adhoc-release.dmg'),
      asset('Kurako-Windows-x64-1.2.0-unsigned-setup.exe'),
      asset('Kurako-Windows-x64-1.2.0-release.zip'),
      asset('Kurako-Linux-1.2.0+4-x86_64.deb'),
      asset('Kurako-Setup-1.2.0.exe'),
    ]);

    String only(String platform, String architecture) => compatibleUpdateAssets(
      release,
      platform: platform,
      architecture: architecture,
    ).single.name;

    expect(
      only('android', 'arm64-v8a'),
      'Kurako-Android-arm64-v8a-1.2.0-release.apk',
    );
    expect(
      only('android', 'armeabi-v7a'),
      'Kurako-Android-armeabi-v7a-1.2.0-release.apk',
    );
    expect(
      only('android', 'x86_64'),
      'Kurako-Android-x86_64-1.2.0-release.apk',
    );
    expect(only('ios', 'other'), 'Kurako-iOS-1.2.0-no_sign-release.ipa');
    expect(
      only('macos', 'other'),
      'Kurako-macOS-1.2.0-universal-adhoc-release.dmg',
    );
    // The Linux package name carries the pubspec build suffix.
    expect(only('linux', 'x86_64'), 'Kurako-Linux-1.2.0+4-x86_64.deb');

    // Windows offers the setup and the portable ZIP, but not the APKs.
    final windows = compatibleUpdateAssets(
      release,
      platform: 'windows',
      architecture: 'x86_64',
    ).map((a) => a.name).toList();
    expect(windows, contains('Kurako-Windows-x64-1.2.0-unsigned-setup.exe'));
    expect(windows, contains('Kurako-Windows-x64-1.2.0-release.zip'));
    expect(windows, contains('Kurako-Setup-1.2.0.exe'));

    // An architecture mismatch offers nothing rather than a wrong binary.
    expect(
      compatibleUpdateAssets(release, platform: 'linux', architecture: 'arm64'),
      isEmpty,
    );
    expect(
      compatibleUpdateAssets(
        release,
        platform: 'windows',
        architecture: 'other',
      ),
      isEmpty,
    );
    expect(
      compatibleUpdateAssets(
        release,
        platform: 'other',
        architecture: 'x86_64',
      ),
      isEmpty,
    );
  });

  test('an older Windows Setup-only release still offers the installer', () {
    final release = releaseWithAssets([asset('Kurako-Setup-1.2.0.exe')]);
    expect(
      compatibleUpdateAssets(
        release,
        platform: 'windows',
        architecture: 'x86_64',
      ).single.name,
      'Kurako-Setup-1.2.0.exe',
    );
  });

  test('a v-prefixed tag still matches the unprefixed asset names', () {
    final release = AppUpdateRelease(
      tagName: 'v1.2.0',
      htmlUrl: 'https://github.com/Tesget512/Kurako/releases/tag/v1.2.0',
      name: 'v1.2.0',
      assets: [
        AppUpdateAsset(
          name: 'Kurako-Android-arm64-v8a-1.2.0-release.apk',
          size: 1024,
          url:
              'https://github.com/Tesget512/Kurako/releases/download/v1.2.0/Kurako-Android-arm64-v8a-1.2.0-release.apk',
        ),
      ],
    );
    expect(
      compatibleUpdateAssets(
        release,
        platform: 'android',
        architecture: 'arm64-v8a',
      ),
      hasLength(1),
    );
  });

  test('SemVer compares numbers, build metadata and prerelease precedence', () {
    int compare(String a, String b) => AppSemanticVersion.tryParse(
      a,
    )!.compareTo(AppSemanticVersion.tryParse(b)!);
    expect(compare('v1.10.0', '1.9.0'), greaterThan(0));
    expect(compare('1.0.2+99', '1.0.2+3'), 0);
    expect(compare('1.0.2', '1.0.3'), lessThan(0));
    final precedence = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ];
    for (var i = 0; i < precedence.length - 1; i++) {
      expect(compare(precedence[i], precedence[i + 1]), lessThan(0));
    }
  });

  test('invalid versions are rejected rather than guessed', () {
    for (final value in [
      '1.2',
      '1.2.3.4',
      'vv1.2.3',
      '01.2.3',
      '1.2.3-01',
      'latest',
      '1.2.3+',
    ]) {
      expect(AppSemanticVersion.tryParse(value), isNull, reason: value);
    }
  });

  test('release URL accepts only project tag pages', () {
    expect(isProjectReleaseUrl(release().htmlUrl), isTrue);
    for (final value in [
      'http://github.com/Tesget512/Kurako/releases/tag/v1',
      'https://github.com:443/Tesget512/Kurako/releases/tag/v1',
      'https://user@github.com/Tesget512/Kurako/releases/tag/v1',
      'https://github.com.evil/Tesget512/Kurako/releases/tag/v1',
      'https://github.com/other/Kurako/releases/tag/v1',
      'https://github.com/Tesget512/Kurako/releases/download/v1/app.apk',
      'https://github.com/Tesget512/Kurako/releases/tag/',
      '${release().htmlUrl}?x=1',
      '${release().htmlUrl}#x',
      '${release().htmlUrl}/../other',
      'https://github.com/Tesget512/Kurako/releases/tag/a%2Fb',
    ]) {
      expect(isProjectReleaseUrl(value), isFalse, reason: value);
    }
  });

  test('uses PackageInfo installed version and ignores build number', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Kurako',
      packageName: 'kurako',
      version: '1.2.0',
      buildNumber: '3',
      buildSignature: '',
    );
    final result = await AppUpdateService(
      fetchLatestRelease: () async => release('v1.2.0+9'),
    ).check();
    expect(result.currentVersion, '1.2.0');
    expect(result.hasNewVersion, isFalse);
  });

  test('latest release still must be newer than installed version', () async {
    expect((await service(installed: '1.3.0').check()).hasNewVersion, isFalse);
    expect((await service().check()).hasNewVersion, isTrue);
    expect((await service(fetch: () async => null).check()).release, isNull);
  });

  test('malformed or prerelease tags and untrusted links fail check', () async {
    for (final latest in [
      release('latest'),
      release('v2.0.0-beta'),
      const AppUpdateRelease(
        tagName: 'v2.0.0',
        htmlUrl: 'https://example.com',
        name: 'bad',
      ),
    ]) {
      await expectLater(
        service(fetch: () async => latest).check(),
        throwsFormatException,
      );
    }
    await expectLater(
      service(installed: 'unknown').check(),
      throwsFormatException,
    );
  });

  test('open release validates URL and handles launcher errors', () async {
    var called = 0;
    final backend = service(
      open: (uri) async {
        called++;
        expect(uri.toString(), release().htmlUrl);
        throw StateError('launcher unavailable');
      },
    );
    expect(
      await backend.openRelease(
        const AppUpdateRelease(
          tagName: 'v2',
          htmlUrl: 'https://example.com',
          name: 'bad',
        ),
      ),
      isFalse,
    );
    expect(called, 0);
    expect(await backend.openRelease(release()), isFalse);
    expect(called, 1);
  });

  test(
    'startup is once and concurrent manual checks share the same flight',
    () async {
      final pending = Completer<AppUpdateRelease?>();
      var requests = 0;
      final notifier = UpdateCheckNotifier(
        service(
          fetch: () {
            requests++;
            return pending.future;
          },
        ),
      );
      addTearDown(notifier.dispose);
      final first = notifier.checkAtStartup();
      final second = notifier.checkManually();
      expect(identical(first, second), isTrue);
      expect(notifier.state.status, UpdateCheckStatus.checking);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      pending.complete(release());
      await first;
      expect(notifier.state.showBanner, isTrue);
      await notifier.checkAtStartup();
      expect(requests, 1);
    },
  );

  test('failure is safe and manual retry succeeds', () async {
    var requests = 0;
    final notifier = UpdateCheckNotifier(
      service(
        fetch: () async {
          if (++requests == 1) throw StateError('secret-proxy-value');
          return release();
        },
      ),
    );
    addTearDown(notifier.dispose);
    await notifier.checkAtStartup();
    expect(notifier.state.status, UpdateCheckStatus.failed);
    expect(notifier.state.showBanner, isFalse);
    expect(
      notifier.state.failureMessage,
      isNot(contains('secret-proxy-value')),
    );
    await notifier.checkManually();
    expect(notifier.state.status, UpdateCheckStatus.available);
    expect(requests, 2);
  });

  test(
    'banner dismissal lasts for this version; a different version can prompt',
    () async {
      var tag = 'v1.2.0';
      final notifier = UpdateCheckNotifier(
        service(fetch: () async => release(tag)),
      );
      addTearDown(notifier.dispose);
      await notifier.checkManually();
      notifier.dismissBanner();
      expect(notifier.state.showBanner, isFalse);
      await notifier.checkManually();
      expect(notifier.state.showBanner, isFalse);
      tag = 'v1.3.0';
      await notifier.checkManually();
      expect(notifier.state.showBanner, isTrue);
    },
  );

  test('no public stable release is distinct from up to date', () async {
    final notifier = UpdateCheckNotifier(service(fetch: () async => null));
    addTearDown(notifier.dispose);
    await notifier.checkAtStartup();
    expect(notifier.state.status, UpdateCheckStatus.noRelease);
    expect(notifier.state.showBanner, isFalse);
  });

  test('dispose while checking does not publish or throw', () async {
    final pending = Completer<AppUpdateRelease?>();
    final notifier = UpdateCheckNotifier(service(fetch: () => pending.future));
    final flight = notifier.checkManually();
    notifier.dispose();
    pending.complete(release());
    await flight;
    await notifier.checkManually();
    expect(await notifier.openRelease(), isFalse);
  });

  testWidgets(
    'host preserves child, displays only new release and supports dismiss',
    (tester) async {
      final backend = service(open: (_) async => false);
      final container = ProviderContainer(
        overrides: [appUpdateServiceProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: updateNavigatorKey,
            builder: bannerBuilder,
            home: const Scaffold(body: Text('app content')),
          ),
        ),
      );
      expect(find.text('app content'), findsOneWidget);
      expect(find.text('下载'), findsNothing);
      await container.read(updateCheckProvider.notifier).checkAtStartup();
      await tester.pump();
      expect(find.text('Kurako v1.2.0 可用'), findsOneWidget);
      // The banner button opens the in-app download dialog rather than a
      // browser page.
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(find.text('更新至 v1.2.0'), findsOneWidget);
      expect(find.text('此版本未提供适用于当前设备的更新包。'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dismiss-update-banner')));
      await tester.pump();
      expect(find.text('下载'), findsNothing);
      expect(find.text('app content'), findsOneWidget);
    },
  );

  testWidgets('320 wide overlay does not resize navigator or block body', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [appUpdateServiceProvider.overrideWithValue(service())],
    );
    addTearDown(container.dispose);
    var taps = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: updateNavigatorKey,
          builder: bannerBuilder,
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('body action'),
              ),
            ),
          ),
        ),
      ),
    );
    final sizeBefore = tester.getSize(find.byType(Scaffold));
    await container.read(updateCheckProvider.notifier).checkAtStartup();
    await tester.pump();
    expect(tester.getSize(find.byType(Scaffold)), sizeBefore);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('body action'));
    expect(taps, 1);
  });

  testWidgets('about page manual failure retry and in-app download', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Kurako',
      packageName: 'kurako',
      version: '1.0.2',
      buildNumber: '3',
      buildSignature: '',
    );
    var requests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateServiceProvider.overrideWithValue(
            service(
              fetch: () async {
                if (++requests == 1) throw StateError('offline');
                return releaseWithAssets([
                  asset('Kurako-Android-arm64-v8a-1.2.0-release.apk'),
                ]);
              },
            ),
          ),
        ],
        child: const MaterialApp(home: AboutPage()),
      ),
    );
    await tester.pumpAndSettle();
    // The removed sentence must not come back.
    expect(find.textContaining('不会自动下载或安装'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '检查更新'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发现新版本 v1.2.0'), findsOneWidget);
    await tester.ensureVisible(find.text('下载更新'));
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.text('更新至 v1.2.0'), findsOneWidget);
  });
}

Widget bannerBuilder(BuildContext context, Widget? child) =>
    UpdateBannerHost(child: child ?? const SizedBox.shrink());
