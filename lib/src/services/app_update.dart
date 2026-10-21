import 'dart:ffi';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// One file attached to a release. `digest` is GitHub's own
/// `sha256:<64 hex>` string, present on recently uploaded assets.
class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.size,
    required this.url,
    this.digest,
    this.sizeKnown = true,
  });

  final String name;
  final int size;
  final String url;
  final String? digest;

  /// False when the metadata source does not publish sizes (the non-API
  /// release page). Such an asset is still offered; the downloader then
  /// verifies the transfer against the response's own Content-Length.
  final bool sizeKnown;
}

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tagName,
    required this.htmlUrl,
    required this.name,
    this.assets = const [],
  });

  final String tagName;
  final String htmlUrl;
  final String name;
  final List<AppUpdateAsset> assets;
}

bool isProjectReleaseUrl(String value) {
  const prefix = 'https://github.com/Tesget512/Kurako/releases/tag/';
  final uri = Uri.tryParse(value);
  if (uri == null || !value.startsWith(prefix)) return false;
  final rawTag = value.substring(prefix.length);
  if (rawTag.contains('/') || rawTag.contains('\\')) return false;
  final segments = uri.pathSegments;
  return uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      segments.length == 5 &&
      segments.take(4).join('/') == 'Tesget512/Kurako/releases/tag' &&
      segments.last.isNotEmpty &&
      segments.last != '.' &&
      segments.last != '..' &&
      !segments.last.contains('/') &&
      !segments.last.contains('\\');
}

/// Only a project asset on the exact release the user was offered is accepted:
/// an HTTPS `github.com/Tesget512/Kurako/releases/download/<tag>/<name>` URL
/// whose tag and file name match the metadata. Everything else — other hosts,
/// ports, credentials, queries, fragments or a different tag — is rejected
/// before any request is made.
bool isProjectAssetUrl(AppUpdateRelease release, AppUpdateAsset asset) {
  final uri = Uri.tryParse(asset.url);
  if (uri == null ||
      !RegExp(r'^[A-Za-z0-9.+_-]+$').hasMatch(asset.name) ||
      !asset.name.startsWith('Kurako-') ||
      // A zero size is only acceptable when the source explicitly says the
      // size is unknown; a published size of 0 is still rejected.
      (!asset.sizeKnown && asset.size != 0) ||
      (asset.sizeKnown && asset.size <= 0) ||
      asset.size > 1024 * 1024 * 1024) {
    return false;
  }
  if (asset.digest != null &&
      !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(asset.digest!)) {
    return false;
  }
  return asset.url.startsWith(
        'https://github.com/Tesget512/Kurako/releases/download/',
      ) &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.pathSegments.length == 6 &&
      uri.pathSegments.take(4).join('/') ==
          'Tesget512/Kurako/releases/download' &&
      uri.pathSegments[4] == release.tagName &&
      uri.pathSegments[5] == asset.name;
}

/// The assets that can actually be installed on this platform/architecture,
/// following the project's distribution naming.
List<AppUpdateAsset> compatibleUpdateAssets(
  AppUpdateRelease release, {
  required String platform,
  required String architecture,
}) {
  final version = release.tagName.replaceFirst(RegExp(r'^[vV]'), '');
  return release.assets.where((asset) {
    if (!isProjectAssetUrl(release, asset)) return false;
    final name = asset.name;
    return switch (platform) {
      'android' => name == 'Kurako-Android-$architecture-$version-release.apk',
      'ios' => name == 'Kurako-iOS-$version-no_sign-release.ipa',
      'macos' => name == 'Kurako-macOS-$version-universal-adhoc-release.dmg',
      // Both the older `Kurako-Setup-*.exe` and the current unsigned setup or
      // portable ZIP are accepted, so an update is offered across the rename.
      'windows' =>
        architecture == 'x86_64' &&
            (name == 'Kurako-Setup-$version.exe' ||
                name == 'Kurako-Windows-x64-$version-unsigned-setup.exe' ||
                name == 'Kurako-Windows-x64-$version-release.zip'),
      // The Linux package name carries the pubspec build suffix.
      'linux' =>
        architecture == 'x86_64' &&
            RegExp(
              '^Kurako-Linux-${RegExp.escape(version)}(?:\\+\\d+)?-x86_64\\.deb\$',
            ).hasMatch(name),
      _ => false,
    };
  }).toList();
}

/// The running platform and CPU architecture, named the way the release assets
/// are. Resolved from the real ABI so a 32-bit install does not offer a 64-bit
/// package.
({String platform, String architecture}) currentUpdateTarget() {
  final architecture = switch (Abi.current()) {
    Abi.androidArm64 => 'arm64-v8a',
    Abi.androidArm => 'armeabi-v7a',
    Abi.androidX64 => 'x86_64',
    Abi.windowsX64 || Abi.linuxX64 => 'x86_64',
    _ => 'other',
  };
  final platform = Platform.isAndroid
      ? 'android'
      : Platform.isIOS
      ? 'ios'
      : Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : Platform.isLinux
      ? 'linux'
      : 'other';
  return (platform: platform, architecture: architecture);
}

/// SemVer precedence, independent of build numbers and the Rust crate version.
/// GitHub tags may have a single leading v; malformed versions are never guessed.
class AppSemanticVersion implements Comparable<AppSemanticVersion> {
  AppSemanticVersion._(this.numbers, this.prerelease);

  final List<BigInt> numbers;
  final List<String> prerelease;

  static AppSemanticVersion? tryParse(String value) {
    final match = RegExp(
      r'^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final pre = match.group(4)?.split('.') ?? const <String>[];
    if (pre.any(
      (p) => RegExp(r'^\d+$').hasMatch(p) && p.length > 1 && p.startsWith('0'),
    )) {
      return null;
    }
    return AppSemanticVersion._([
      for (var i = 1; i <= 3; i++) BigInt.parse(match.group(i)!),
    ], pre);
  }

  @override
  int compareTo(AppSemanticVersion other) {
    for (var i = 0; i < 3; i++) {
      final order = numbers[i].compareTo(other.numbers[i]);
      if (order != 0) return order;
    }
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final left = prerelease[i];
      final right = other.prerelease[i];
      final leftNumber = BigInt.tryParse(left);
      final rightNumber = BigInt.tryParse(right);
      final int order;
      if (leftNumber != null && rightNumber != null) {
        order = leftNumber.compareTo(rightNumber);
      } else if (leftNumber != null) {
        order = -1;
      } else if (rightNumber != null) {
        order = 1;
      } else {
        order = left.compareTo(right);
      }
      if (order != 0) return order;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({required this.currentVersion, this.release});
  final String currentVersion;
  final AppUpdateRelease? release;

  bool get hasNewVersion {
    final latest = release;
    if (latest == null) return false;
    return AppSemanticVersion.tryParse(
          latest.tagName,
        )!.compareTo(AppSemanticVersion.tryParse(currentVersion)!) >
        0;
  }
}

class AppUpdateService {
  AppUpdateService({
    required this.fetchLatestRelease,
    Future<String> Function()? readInstalledVersion,
    Future<bool> Function(Uri)? openUrl,
  }) : readInstalledVersion = readInstalledVersion ?? _installedVersion,
       openUrl = openUrl ?? _openExternal;

  final Future<AppUpdateRelease?> Function() fetchLatestRelease;
  final Future<String> Function() readInstalledVersion;
  final Future<bool> Function(Uri) openUrl;

  static Future<String> _installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static Future<bool> _openExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<UpdateCheckResult> check() async {
    final current = await readInstalledVersion();
    if (AppSemanticVersion.tryParse(current) == null) {
      throw const FormatException('无法识别当前应用版本');
    }
    final release = await fetchLatestRelease();
    if (release != null) {
      final version = AppSemanticVersion.tryParse(release.tagName);
      if (version == null ||
          version.prerelease.isNotEmpty ||
          !isProjectReleaseUrl(release.htmlUrl)) {
        throw const FormatException('GitHub 返回的稳定版本信息无效');
      }
    }
    return UpdateCheckResult(currentVersion: current, release: release);
  }

  Future<bool> openRelease(AppUpdateRelease release) async {
    if (!isProjectReleaseUrl(release.htmlUrl)) return false;
    try {
      return await openUrl(Uri.parse(release.htmlUrl));
    } catch (_) {
      return false;
    }
  }
}
