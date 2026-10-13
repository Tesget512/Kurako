import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../services/bangumi_mirror.dart';
import '../state/providers.dart';

/// Synchronous reservation shared with maintenance/source mutations.
final libraryMutationBusyProvider = StateProvider<bool>((ref) => false);

/// Not autoDispose: navigation must not own or interrupt a scan session.
final scanCoordinatorProvider =
    StateNotifierProvider<ScanCoordinator, ScanState>((ref) {
      return ScanCoordinator(
        RustScanBackend(),
        canStart: () => !ref.read(libraryMutationBusyProvider),
        onLibraryChanged: () {
          ref.invalidate(animeListProvider);
          ref.invalidate(animeDetailProvider);
          ref.invalidate(episodesProvider);
          ref.invalidate(foldersProvider);
        },
      );
    });

class ScanState {
  final bool running;
  final bool cancelling;
  final ScanProgress? progress;
  final String? error;
  final List<String> warnings;
  const ScanState({
    this.running = false,
    this.cancelling = false,
    this.progress,
    this.error,
    this.warnings = const [],
  });

  bool get visible => running || progress != null || error != null;
  String get label => cancelling
      ? '正在停止扫描…'
      : error != null
      ? '扫描失败：$error'
      : progress?.message ?? '准备扫描…';
}

/// The injectable boundary keeps lifecycle tests independent of FRB/devices.
abstract class ScanBackend {
  Future<void> begin(bool incremental);
  Future<void> close();
  Future<void> cancel();
  Future<bool> isCancelled();
  Future<void> clear();
  Future<void> awake(bool enabled);
  Future<List<LibraryFolder>> folders();
  Future<List<ScannedFile>> enumerate(
    LibraryFolder folder,
    bool incremental,
    bool Function() isCancelled,
  );
  Stream<ScanProgress> process(LibraryFolder folder, List<ScannedFile> files);
  Stream<ScanProgress> finish();
  Future<void> claimExisting(LibraryFolder folder);
}

class RustScanBackend implements ScanBackend {
  @override
  Future<void> begin(bool incremental) =>
      rust.scanSessionBegin(incremental: incremental);
  @override
  Future<void> close() => rust.scanSessionClose();
  @override
  Future<void> cancel() => rust.scanSessionCancel();
  @override
  Future<bool> isCancelled() => rust.scanSessionIsCancelled();
  @override
  Future<void> clear() => rust.clearLibrary();
  @override
  Future<void> awake(bool enabled) =>
      enabled ? WakelockPlus.enable() : WakelockPlus.disable();
  @override
  Future<List<LibraryFolder>> folders() => rust.listLibraryFolders();
  @override
  Future<List<ScannedFile>> enumerate(
    LibraryFolder folder,
    bool incremental,
    bool Function() isCancelled,
  ) async {
    if (folder.sourceType == 'local') {
      return (await rust.enumerateLocalFolder(
        folderId: folder.id,
        incremental: incremental,
      )).files;
    }
    final source = switch (folder.sourceType) {
      'smb' => SmbMediaSource(),
      'webdav' => WebDavMediaSource(),
      _ => SafMediaSource(),
    };
    return source.enumerate(folder.path, isCancelled: isCancelled);
  }

  @override
  Stream<ScanProgress> process(LibraryFolder folder, List<ScannedFile> files) =>
      rust.scanFilesAndMatch(
        folderId: folder.id,
        files: files,
        sourceType: folder.sourceType,
      );
  @override
  Stream<ScanProgress> finish() => rust.finishScanAndMatch();
  @override
  Future<void> claimExisting(LibraryFolder folder) async {
    await rust.claimExistingFolderFiles(folderId: folder.id);
  }
}

class ScanCoordinator extends StateNotifier<ScanState> {
  final ScanBackend backend;
  final void Function() onLibraryChanged;
  final bool Function() canStart;
  bool _cancelRequested = false;
  bool _ownsSession = false;
  ScanCoordinator(
    this.backend, {
    required this.onLibraryChanged,
    bool Function()? canStart,
  }) : canStart = canStart ?? (() => true),
       super(const ScanState());

  void _publish(ScanState value) {
    if (mounted) state = value;
  }

  void _progress(ScanProgress progress) {
    _publish(
      ScanState(
        running: true,
        cancelling: _cancelRequested,
        progress: progress,
        warnings: state.warnings,
      ),
    );
  }

  Future<void> start({bool incremental = true, bool clearFirst = false}) async {
    if (state.running) return;
    if (!canStart()) {
      _publish(const ScanState(error: '维护操作正在进行，请完成后再扫描'));
      return;
    }
    _cancelRequested = false;
    _publish(const ScanState(running: true));
    String? error;
    var changed = false;
    try {
      // Wake-lock plugins can be unavailable; cleanup is attempted either way.
      try {
        await backend.awake(true);
      } catch (_) {}
      final folders = await backend.folders();
      if (folders.isEmpty) throw StateError('请先在设置中添加番剧文件夹');
      if (_cancelRequested) return;
      await backend.begin(incremental);
      _ownsSession = true;
      if (_cancelRequested) {
        await backend.cancel();
        return;
      }
      if (clearFirst) {
        await backend.clear();
        changed = true;
      }
      for (final folder in folders) {
        if (_cancelRequested || await backend.isCancelled()) break;
        _progress(
          ScanProgress(
            stage: 'enumerating',
            current: 0,
            total: 0,
            message: '列举 ${folder.path}',
          ),
        );
        late final List<ScannedFile> files;
        try {
          files = await backend.enumerate(
            folder,
            incremental,
            () => _cancelRequested,
          );
        } catch (e) {
          if (_cancelRequested || await backend.isCancelled()) break;
          await backend.claimExisting(folder);
          changed = true;
          _publish(
            ScanState(
              running: true,
              progress: state.progress,
              warnings: [...state.warnings, '${folder.path}：$e'],
            ),
          );
          continue;
        }
        if (_cancelRequested || await backend.isCancelled()) break;
        changed = true;
        await for (final progress in backend.process(folder, files)) {
          _progress(progress);
        }
      }
      if (!_cancelRequested && !await backend.isCancelled()) {
        changed = true;
        await for (final progress in backend.finish()) {
          _progress(progress);
        }
      }
    } catch (e) {
      if (!_cancelRequested) {
        BangumiMirrorService.instance.reportApiFailure(e);
        error = e.toString();
      }
    } finally {
      try {
        if (_ownsSession) await backend.close();
      } catch (e) {
        error ??= e.toString();
      } finally {
        _ownsSession = false;
        try {
          await backend.awake(false);
        } catch (_) {}
      }
      if (mounted) {
        if (changed) onLibraryChanged();
        _publish(
          ScanState(
            error: error,
            warnings: state.warnings,
            progress: ScanProgress(
              stage: _cancelRequested ? 'cancelled' : 'done',
              current: 0,
              total: 0,
              message: _cancelRequested
                  ? '扫描已停止，已完成的文件夹保留'
                  : state.progress?.stage == 'warning'
                  ? state.progress!.message
                  : state.warnings.isNotEmpty
                  ? '扫描完成，部分文件夹未能读取'
                  : '扫描完成',
            ),
          ),
        );
      }
    }
  }

  Future<void> cancel() async {
    if (!state.running || _cancelRequested) return;
    _cancelRequested = true;
    _publish(
      ScanState(
        running: true,
        cancelling: true,
        progress: state.progress,
        warnings: state.warnings,
      ),
    );
    if (_ownsSession) await backend.cancel();
  }

  void dismiss() {
    if (!state.running) state = const ScanState();
  }

  @override
  void dispose() {
    _cancelRequested = true;
    if (_ownsSession) backend.cancel();
    super.dispose();
  }
}
