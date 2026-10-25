import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/rust/models.dart';
import 'package:kurako/src/services/scan_coordinator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FakeScanBackend implements ScanBackend {
  Completer<void> entered = Completer<void>();
  Completer<List<ScannedFile>> enumerated = Completer<List<ScannedFile>>();
  String preliminaryMessage =
      'ok\nstats: folder=7|checked=10|changed=3|removed=1';
  String finishMessage =
      '完成\nmatch-result: matched=0|unmatched=2|failed=0\n'
      'match-attempted: 2/3\nunmatched: 剧场版 A\nunmatched: 剧场版 B';
  int begins = 0;
  int closes = 0;
  int clears = 0;
  int finishes = 0;
  bool cancelled = false;
  bool failBegin = false;
  final awakeCalls = <bool>[];
  @override
  Future<void> begin(bool incremental) async {
    begins++;
    if (failBegin) throw StateError('busy');
  }

  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> close() async => closes++;
  @override
  Future<bool> isCancelled() async => cancelled;
  @override
  Future<void> clear() async => clears++;
  @override
  Future<void> awake(bool enabled) async => awakeCalls.add(enabled);
  @override
  Future<List<LibraryFolder>> folders() async => [
    const LibraryFolder(
      id: 1,
      path: '/media',
      addedAt: 1,
      priority: 0,
      sourceType: 'local',
    ),
  ];
  @override
  Future<List<ScannedFile>> enumerate(
    LibraryFolder folder,
    bool incremental,
    bool Function() isCancelled,
  ) {
    entered.complete();
    return enumerated.future;
  }

  @override
  Future<void> claimExisting(LibraryFolder folder) async {}
  @override
  Stream<ScanProgress> process(
    LibraryFolder folder,
    List<ScannedFile> files,
  ) async* {
    yield ScanProgress(
      stage: 'scanning',
      current: 1,
      total: 1,
      message: preliminaryMessage,
    );
  }

  @override
  Stream<ScanProgress> finish() async* {
    finishes++;
    yield ScanProgress(
      stage: 'done',
      current: 1,
      total: 1,
      message: finishMessage,
    );
  }
}

/// Riverpod 3 Notifiers only work container-mounted; stand up
/// scanCoordinatorProvider with the test's injected coordinator.
(ScanCoordinator, ProviderContainer) _mounted(ScanCoordinator coordinator) {
  final container = ProviderContainer(
    overrides: [scanCoordinatorProvider.overrideWith(() => coordinator)],
  );
  final mounted = container.read(scanCoordinatorProvider.notifier);
  return (mounted, container);
}

void main() {
  test(
    'single session cancels without finish and always releases wake lock',
    () async {
      final backend = FakeScanBackend();
      final rawCoordinator = ScanCoordinator(backend, onLibraryChanged: () {});
      final (coordinator, container) = _mounted(rawCoordinator);
      final run = coordinator.start();
      await backend.entered.future;
      await coordinator.start(clearFirst: true);
      expect(backend.begins, 1);
      expect(backend.clears, 0);
      await coordinator.cancel();
      backend.enumerated.complete([]);
      await run;
      expect(backend.finishes, 0);
      expect(backend.closes, 1);
      expect(backend.awakeCalls, [true, false]);
      // Cancelling dismisses the bar immediately; a native call that cannot be
      // interrupted must not leave the user stuck in a scan they stopped.
      expect(coordinator.state.running, false);
      expect(coordinator.state.progress, isNull);
      container.dispose();
    },
  );

  test('maintenance reservation prevents any scan backend operation', () async {
    final backend = FakeScanBackend();
    final raw = ScanCoordinator(
      backend,
      onLibraryChanged: () {},
      canStart: () => false,
    );
    final (coordinator, container) = _mounted(raw);
    await coordinator.start(clearFirst: true);
    expect(backend.begins, 0);
    expect(backend.awakeCalls, isEmpty);
    expect(coordinator.state.error, contains('维护'));
    container.dispose();
  });

  test('failed begin cannot clear index or close another session', () async {
    final backend = FakeScanBackend()..failBegin = true;
    final rawCoordinator = ScanCoordinator(backend, onLibraryChanged: () {});
    final (coordinator, container) = _mounted(rawCoordinator);
    await coordinator.start(clearFirst: true);
    expect(backend.clears, 0);
    expect(backend.closes, 0);
    expect(backend.awakeCalls, [true, false]);
    expect(coordinator.state.error, contains('busy'));
    container.dispose();
  });

  test('disposing UI owner cancels and cleanup still completes', () async {
    final backend = FakeScanBackend();
    final rawCoordinator = ScanCoordinator(backend, onLibraryChanged: () {});
    final (coordinator, container) = _mounted(rawCoordinator);
    final run = coordinator.start();
    await backend.entered.future;
    container.dispose();
    backend.enumerated.complete([]);
    await run;
    expect(backend.cancelled, true);
    expect(backend.closes, 1);
    expect(backend.awakeCalls.last, false);
  });

  test(
    'structured scan events accumulate per-folder stats and unmatched',
    () async {
      final backend = FakeScanBackend();
      final rawCoordinator = ScanCoordinator(backend, onLibraryChanged: () {});
      final (coordinator, container) = _mounted(rawCoordinator);
      final run = coordinator.start();
      await backend.entered.future;
      backend.enumerated.complete([]);
      await run;
      expect(coordinator.state.folders['7']?.checked, 10);
      expect(coordinator.state.folders['7']?.changed, 3);
      expect(coordinator.state.folders['7']?.removed, 1);
      expect(coordinator.state.matchAttempted, '2/3');
      expect(coordinator.state.unmatchedTitles, ['剧场版 A', '剧场版 B']);
      // The status bar keeps showing only the human-readable first line; the
      // coordinator's closing event uses its own summary wording.
      expect(coordinator.state.label, '扫描完成');
      // Parsing is side-effect free: the plain event stays a plain event.
      final plain = ScanEventFacts.parse('检查 10 个视频');
      expect(plain.stats, isNull);
      expect(plain.unmatched, isEmpty);
      coordinator.dismiss();
      expect(coordinator.state.visible, false);
      container.dispose();
    },
  );

  test('final scan report replaces stale unmatched entries', () async {
    final backend = FakeScanBackend();
    backend.preliminaryMessage = '扫描中\nunmatched: 已被成功匹配的旧标题';
    final rawCoordinator = ScanCoordinator(backend, onLibraryChanged: () {});
    final (coordinator, container) = _mounted(rawCoordinator);
    final run = coordinator.start();
    await backend.entered.future;
    backend.enumerated.complete([]);
    await run;
    expect(coordinator.state.unmatchedTitles, ['剧场版 A', '剧场版 B']);

    backend.entered = Completer<void>();
    backend.enumerated = Completer<List<ScannedFile>>();
    backend.finishMessage =
        '完成\nmatch-result: matched=1|unmatched=1|failed=0\n'
        'match-attempted: 1/1\nmatched: 已匹配番剧\n'
        'unmatched: 仍然未匹配';
    final second = coordinator.start();
    await backend.entered.future;
    backend.enumerated.complete(const []);
    await second;
    expect(coordinator.state.unmatchedTitles, ['仍然未匹配']);
    expect(coordinator.state.matchedTitles, ['已匹配番剧']);
    container.dispose();
  });

  test('scan report separates matched titles from unmatched titles', () {
    final facts = ScanEventFacts.parse(
      '完成\nmatch-result: matched=1|unmatched=1|failed=0\n'
      'matched: 已匹配番剧\nunmatched: 未匹配番剧',
    );
    expect(facts.matched, ['已匹配番剧']);
    expect(facts.unmatched, ['未匹配番剧']);
  });
}
