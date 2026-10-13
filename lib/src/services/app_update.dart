import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Metadata only; no asset URLs or installation API are exposed.
class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tagName,
    required this.htmlUrl,
    required this.name,
  });

  final String tagName;
  final String htmlUrl;
  final String name;
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
