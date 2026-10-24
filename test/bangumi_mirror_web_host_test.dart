import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kurako/src/pages/bangumi_mirror_verification_page.dart';
import 'package:kurako/src/services/bangumi_mirror.dart';
import 'package:kurako/src/services/bangumi_mirror_web_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fake host JSON becomes a readable success state', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: '{"id":541285,"name":"きみが死ぬまで恋をしたい"}',
                  supportsFlutterOverlay: true,
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(host.loadedUri, Uri.parse(bangumiMirrorApiProbe));
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pumpAndSettle();

    expect(find.text('API 已可直接访问'), findsOneWidget);
    expect(find.text('检查并继续'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host')), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host-view')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(host.disposeCount, 1);
  });

  testWidgets('Linux host is removed while a Flutter result panel is shown', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: '{"id":541285,"name":"きみが死ぬまで恋をしたい"}',
                  supportsFlutterOverlay: false,
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pumpAndSettle();

    expect(find.text('API 已可直接访问'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host')), findsNothing);
    expect(find.byKey(const Key('mirror-web-host-view')), findsNothing);
  });

  testWidgets('old stage completion cannot clear the image-stage watchdog', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: '{"id":541285,"name":"きみが死ぬまで恋をしたい"}',
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pump();
    await tester.pump();
    final apiGeneration = host.generation;

    await tester.tap(find.text('检查并继续'));
    await tester.pump();
    await tester.pump();
    expect(host.loadedUri, Uri.parse('https://lain.bangumi.lat/cover.jpg'));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    host.finishLoadAt(apiGeneration, Uri.parse(bangumiMirrorApiProbe));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    host.finishLoad(Uri.parse('https://lain.bangumi.lat/cover.jpg'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('an action failure remains retryable', (tester) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async {
            throw const BangumiMirrorException('temporary failure');
          },
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: 'Anubis challenge',
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('检查并继续'));
    await tester.pump();
    await tester.pump();

    expect(find.text('temporary failure'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
    expect(find.byKey(const Key('mirror-web-host-view')), findsOneWidget);
  });

  testWidgets('image load failure unlocks the verification action', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: '{"id":541285,"name":"きみが死ぬまで恋をしたい"}',
                  failLoadUri: Uri.parse('https://lain.bangumi.lat/cover.jpg'),
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('检查并继续'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('无法加载图片验证页面'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('blocked navigation is reported before the host is removed', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    host.block(Uri.parse('https://example.test/login'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('尝试离开受信任域名'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host-view')), findsNothing);
  });

  testWidgets('watchdog replaces a blank iOS-style page with a timeout', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          loadTimeout: const Duration(seconds: 5),
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(find.textContaining('验证页面加载超时'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host')), findsNothing);
  });

  testWidgets('main-frame failure uses a fixed connection diagnostic', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.fail(
      const MirrorWebLoadError(
        kind: MirrorWebLoadFailureKind.connection,
        uri: null,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('无法连接反向代理验证页面'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host')), findsNothing);
  });

  testWidgets('empty document is reported instead of leaving a blank view', (
    tester,
  ) async {
    late _FakeMirrorWebHost host;
    await tester.pumpWidget(
      MaterialApp(
        home: BangumiMirrorVerificationPage(
          onApiProof: (_) async => 'https://lain.bangumi.lat/cover.jpg',
          onImageProof: (_, _) async {},
          hostFactory:
              ({
                required initialUri,
                required onLoadStart,
                required onLoadStop,
                required onError,
                required onNavigationBlocked,
              }) async {
                host = _FakeMirrorWebHost(
                  initialUri: initialUri,
                  onLoadStart: onLoadStart,
                  onLoadStop: onLoadStop,
                  onError: onError,
                  onNavigationBlocked: onNavigationBlocked,
                  pageText: '',
                );
                return host;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    host.finishLoad(Uri.parse(bangumiMirrorApiProbe));
    await tester.pumpAndSettle();

    expect(find.textContaining('验证页面没有返回内容'), findsOneWidget);
    expect(find.byKey(const Key('mirror-web-host')), findsNothing);
  });
}

class _FakeMirrorWebHost implements MirrorWebHost {
  _FakeMirrorWebHost({
    required this.initialUri,
    required this.onLoadStart,
    required this.onLoadStop,
    required this.onError,
    required this.onNavigationBlocked,
    this.pageText,
    this.supportsFlutterOverlay = true,
    this.failLoadUri,
  });

  final Uri initialUri;
  final MirrorLoadCallback onLoadStart;
  final MirrorLoadCallback onLoadStop;
  final MirrorLoadErrorCallback onError;
  final MirrorNavigationBlockedCallback onNavigationBlocked;
  final String? pageText;
  final Uri? failLoadUri;
  @override
  final bool supportsFlutterOverlay;

  Uri? loadedUri;
  int generation = 0;
  int disposeCount = 0;

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('mirror-web-host-view'), color: Colors.white);

  @override
  Future<void> load(Uri uri, {required int generation}) async {
    if (uri == failLoadUri) {
      throw const BangumiMirrorException('无法加载图片验证页面。');
    }
    this.generation = generation;
    loadedUri = uri;
    onLoadStart(generation, uri);
  }

  void finishLoad(Uri uri) => finishLoadAt(generation, uri);

  void finishLoadAt(int generation, Uri uri) => onLoadStop(generation, uri);

  void fail(MirrorWebLoadError error) => onError(generation, error);

  void block(Uri uri) => onNavigationBlocked(generation, uri);

  @override
  Future<Uri?> currentUri() async => loadedUri;

  @override
  Future<String?> userAgent() async => 'Fake Browser UA';

  @override
  Future<String?> pageTextValue() async => pageText;

  @override
  Future<List<MirrorCookie>> cookies(Uri uri) async => const [];

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}
