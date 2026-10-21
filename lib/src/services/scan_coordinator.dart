import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/media_source.dart';
import '../services/bangumi_mirror.dart';
import '../services/security_scope.dart';
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

/// Per-folder aggregates parsed from a scan event's `stats:` line.
class FolderScanStats {
  final String folderId;
  final int checked;
  final int changed;
  final int removed;
  const FolderScanStats({
    required this.folderId,
    required this.checked,
    required this.changed,
    required this.removed,
  });
}

/// Parsed structured lines from one scan event's message.
class ScanEventFacts {
  final FolderScanStats? stats;
  final List<String> unmatched;
  final String? matchAttempted;
  const ScanEventFacts({
    this.stats,
    this.unmatched = const [],
    this.matchAttempted,
  });

  /// Lines starting with `stats:` / `unmatched:` / `match-attempted:` are
  /// structured summary data appended by Rust; everything else is the
  /// human-readable status line.
  static ScanEventFacts parse(String message) {
    FolderScanStats? stats;
    final unmatched = <String>[];
    String? matchAttempted;
    final status = <String>[];
    for (final line in message.split('\n')) {
      if (line.startsWith('stats: ')) {
        final fields = Map.fromEntries(
          line.substring(7).split('|').map((part) {
            final kv = part.split('=');
            return kv.length == 2 ? MapEntry(kv[0], kv[1]) : null;
          }).nonNulls,
        );
        final folderId = fields['folder'];
        if (folderId != null) {
          stats = FolderScanStats(
            folderId: folderId,
            checked: int.tryParse(fields['checked'] ?? '') ?? 0,
            changed: int.tryParse(fields['changed'] ?? '') ?? 0,
            removed: int.tryParse(fields['removed'] ?? '') ?? 0,
          );
        }
      } else if (line.startsWith('unmatched: ')) {
        final title = line.substring(11).trim();
        if (title.isNotEmpty) unmatched.add(title);
      } else if (line.startsWith('match-attempted: ')) {
        matchAttempted = line.substring(17).trim();
      } else {
        status.add(line);
      }
    }
    return ScanEventFacts(
      stats: stats,
      unmatched: unmatched,
      matchAttempted: matchAttempted,
    );
  }
}

class ScanState {
  final bool running;
  final bool cancelling;
  final ScanProgress? progress;
  final String? error;
  final List<String> warnings;
  final Map<String, FolderScanStats> folders;
  final List<String> unmatchedTitles;
  final String? matchAttempted;
  const ScanState({
    this.running = false,
    this.cancelling = false,
    this.progress,
    this.error,
    this.warnings = const [],
    this.folders = const {},
    this.unmatchedTitles = const [],
    this.matchAttempted,
  });

  bool get visible => running || progress != null || error != null;
  String get label => cancelling
      ? '正在停止扫描…'
      : error != null
      ? '扫描失败：$error'
      : (progress?.message.split('\n').first).takeIfNonEmpty() ?? '准备扫描…';
}

extension _StringX on String? {
  String? takeIfNonEmpty() => this == null || this!.isEmpty ? null : this;
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
      // macOS sandbox: re-activate the folder's security-scoped access for
      // the duration of this enumeration (Rust walkdir needs open() too).
      if (Platform.isMacOS) {
        try {
          final scope = await SecurityScope.access(folder.path);
          try {
            final batch = await rust.enumerateLocalFolder(
              folderId: folder.id,
              incremental: incremental,
            );
            return batch.files;
          } finally {
            await SecurityScope.release(scope.scopePath);
          }
        } on SecurityScopeException catch (error) {
          throw StateError('无法访问文件夹：${error.message}');
        }
      }
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
    // A dismissed/cancelled scan keeps running natively until its blocking
    // call returns; its late progress must not resurrect the UI bar.
    if (_cancelRequested) return;
    final facts = ScanEventFacts.parse(progress.message);
    _publish(
      ScanState(
        running: true,
        cancelling: _cancelRequested,
        progress: progress,
        warnings: state.warnings,
        folders: facts.stats == null
            ? state.folders
            : {...state.folders, facts.stats!.folderId: facts.stats!},
        unmatchedTitles: facts.unmatched.isEmpty
            ? state.unmatchedTitles
            : {
                for (final title in state.unmatchedTitles) title,
                ...facts.unmatched,
              }.toList(),
        matchAttempted: facts.matchAttempted ?? state.matchAttempted,
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
              cancelling: state.cancelling,
              progress: state.progress,
              // Keep what earlier folders already reported; rebuilding the
              // state without them blanked the detail dialog mid-scan.
              warnings: [...state.warnings, '${folder.path}：$e'],
              folders: state.folders,
              unmatchedTitles: state.unmatchedTitles,
              matchAttempted: state.matchAttempted,
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
        // A dismissed scan must not republish a finished bar: the user asked
        // for it to disappear while the native call was still unwinding.
        if (!_cancelRequested) {
          // Keep the accumulated session stats visible after the scan ends: the
          // detail sheet stays inspectable until the user dismisses the bar.
          _publish(
            ScanState(
              error: error,
              warnings: state.warnings,
              folders: state.folders,
              unmatchedTitles: state.unmatchedTitles,
              matchAttempted: state.matchAttempted,
              progress: ScanProgress(
                stage: 'done',
                current: 0,
                total: 0,
                message: state.progress?.stage == 'warning'
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
  }

  /// Stop the scan and hide the inline bar.
  ///
  /// A native call already in flight cannot be interrupted (a hung mount can
  /// block `read_dir` indefinitely), so the UI must not wait for it: the
  /// request flag is set, the bar is dismissed immediately, and the stale
  /// scan future discards its own results because `_cancelRequested` is set.
  Future<void> cancel() async {
    if (!state.running) return;
    _cancelRequested = true;
    if (_ownsSession) {
      try {
        await backend.cancel();
      } catch (_) {
        // The session may already be gone; dismissal still proceeds.
      }
    }
    state = const ScanState();
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
