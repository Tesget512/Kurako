import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/update.dart' as rust;
import '../services/app_update.dart';

/// Map a failed update check to an accurate message. The Rust layer only ever
/// reports fixed reasons, so matching on those keeps the text honest instead
/// of blaming the network for a GitHub quota limit.
String updateFailureMessage(Object error) {
  if (error is FormatException) return error.message.toString();
  final text = error.toString();
  if (text.contains('rate limited')) {
    return 'GitHub 暂时限制了匿名请求频率，请稍后重试。';
  }
  if (text.contains('HTTP 404') || text.contains('no release')) {
    return '暂时没有可用的正式版本。';
  }
  if (text.contains('invalid GitHub release')) {
    return 'GitHub 返回的版本信息无法识别，请稍后重试。';
  }
  return '检查失败，请确认网络或系统代理后重试。';
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(
    fetchLatestRelease: () async {
      final release = await rust.checkUpdate();
      if (release == null) return null;
      return AppUpdateRelease(
        tagName: release.tagName,
        htmlUrl: release.htmlUrl,
        name: release.name,
        assets: [
          for (final asset in release.assets)
            AppUpdateAsset(
              name: asset.name,
              size: asset.size.toInt(),
              url: asset.browserDownloadUrl,
              digest: asset.digest,
              // Rust reports 0 when it resolved the release through the
              // non-API pages, which do not publish asset sizes.
              sizeKnown: asset.size.toInt() > 0,
            ),
        ],
      );
    },
  );
});

final updateCheckProvider =
    NotifierProvider<UpdateCheckNotifier, UpdateCheckState>(
      UpdateCheckNotifier.new,
    );

enum UpdateCheckStatus {
  idle,
  checking,
  noRelease,
  upToDate,
  available,
  failed,
}

class UpdateCheckState {
  const UpdateCheckState({
    this.status = UpdateCheckStatus.idle,
    this.result,
    this.failureMessage,
    this.dismissedTag,
  });

  final UpdateCheckStatus status;
  final UpdateCheckResult? result;
  final String? failureMessage;
  final String? dismissedTag;

  bool get showBanner =>
      status == UpdateCheckStatus.available &&
      result?.release != null &&
      result!.release!.tagName != dismissedTag;
}

/// One instance per application ProviderScope. No network work in its constructor.
/// Startup failures are only observable on the about page, never a modal prompt.
class UpdateCheckNotifier extends Notifier<UpdateCheckState> {
  UpdateCheckNotifier([AppUpdateService? service]) : _injectedService = service;

  final AppUpdateService? _injectedService;
  late final AppUpdateService service;
  Future<void>? _checking;
  bool _startupChecked = false;
  bool _disposed = false;

  @override
  UpdateCheckState build() {
    service = _injectedService ?? ref.watch(appUpdateServiceProvider);
    ref.onDispose(() => _disposed = true);
    return const UpdateCheckState();
  }

  Future<void> checkAtStartup() {
    if (_disposed || _startupChecked) return Future<void>.value();
    // Set before any await, including a concurrent manual request.
    _startupChecked = true;
    return _check();
  }

  Future<void> checkManually() => _check();

  Future<void> _check() {
    if (_disposed) return Future<void>.value();
    if (_checking case final active?) return active;
    final completer = Completer<void>();
    _checking = completer.future;
    state = UpdateCheckState(
      status: UpdateCheckStatus.checking,
      result: state.result,
      dismissedTag: state.dismissedTag,
    );
    unawaited(_runCheck(completer));
    return completer.future;
  }

  Future<void> _runCheck(Completer<void> completer) async {
    try {
      final result = await service.check();
      if (!_disposed) {
        state = UpdateCheckState(
          status: result.release == null
              ? UpdateCheckStatus.noRelease
              : result.hasNewVersion
              ? UpdateCheckStatus.available
              : UpdateCheckStatus.upToDate,
          result: result,
          dismissedTag: state.dismissedTag,
        );
      }
    } catch (error) {
      if (!_disposed) {
        state = UpdateCheckState(
          status: UpdateCheckStatus.failed,
          result: state.result,
          dismissedTag: state.dismissedTag,
          failureMessage: updateFailureMessage(error),
        );
      }
    } finally {
      _checking = null;
      completer.complete();
    }
  }

  void dismissBanner() {
    if (_disposed || state.result?.release == null) return;
    state = UpdateCheckState(
      status: state.status,
      result: state.result,
      failureMessage: state.failureMessage,
      dismissedTag: state.result!.release!.tagName,
    );
  }

  Future<bool> openRelease() async {
    if (_disposed) return false;
    final release = state.result?.release;
    if (release == null) return false;
    return service.openRelease(release);
  }
}
