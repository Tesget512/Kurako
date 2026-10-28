import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/bangumi_mirror_verification_page.dart';
import 'bangumi_mirror_web_host.dart';

const bangumiMirrorApiHost = 'api.bangumi.lat';
const bangumiMirrorProbeSubjectId = 541285;
const bangumiMirrorApiProbe =
    'https://$bangumiMirrorApiHost/v0/subjects/$bangumiMirrorProbeSubjectId';
const bangumiMirrorImageHost = 'lain.bangumi.lat';

/// Browsable site of the reverse proxy. Only used for links the user opens in
/// their own browser; the app never sends API requests or credentials here.
const bangumiMirrorSiteHost = 'bangumi.lat';

/// Subject page the user opens in a browser. Follows the reverse proxy switch
/// so a user who cannot reach the official site is not sent back to it.
Uri bangumiSubjectUri(int subjectId, {required bool mirror}) => Uri(
  scheme: 'https',
  host: mirror ? bangumiMirrorSiteHost : 'bgm.tv',
  path: '/subject/$subjectId',
);
const bangumiMirrorFailureMessage =
    '反向代理验证已失效或请求被拦截。请重新验证，或关闭反向代理回退官方；'
    '请确保 WebView 与应用使用相同网络和代理出口，网络/IP 或 User-Agent 改变会使验证失效。'
    '若浏览器直接访问 bangumi.lat 也异常，多为反向代理服务自身故障，可稍后重试或暂时回退官方。';

/// User-Agent used when probing the mirror directly, without a WebView.
///
/// The API and image hosts answer plain requests (verified against the live
/// service: they return JSON/JPEG with no challenge), so the normal path needs
/// no browser session at all.
const kBangumiMirrorDirectUserAgent = 'Kurako/1.0';

/// These are the only challenge cookie bases accepted. Account cookies never
/// leave the WebView, and document.cookie is deliberately not used for
/// HttpOnly data.
const bangumiAnubisCookieNames = {
  'techaro.lol-anubis-auth',
  'techaro.lol-anubis-cookie-verification',
};

final _anubisCookieSuffix = RegExp(r'^[0-9a-f]{8}$');

/// Anubis v1.27+ adds an eight-character hexadecimal suffix derived from its
/// cookie settings by default. Older deployments and manually configured
/// servers still use the unsuffixed base name.
bool isBangumiAnubisCookieName(String name) {
  for (final base in bangumiAnubisCookieNames) {
    if (name == base) return true;
    if (name.length == base.length + 9 &&
        name.startsWith('$base-') &&
        _anubisCookieSuffix.hasMatch(name.substring(base.length + 1))) {
      return true;
    }
  }
  return false;
}

/// A header scoped to the exact host for which native CookieManager was queried.
/// Unknown metadata (older Android WebView) never broadens that scope.
class BangumiMirrorHostProof {
  final String host;
  final String cookie;
  final String userAgent;
  final int? expiresAt;

  const BangumiMirrorHostProof({
    required this.host,
    required this.cookie,
    required this.userAgent,
    this.expiresAt,
  });

  bool get valid =>
      {bangumiMirrorApiHost, bangumiMirrorImageHost}.contains(host) &&
      userAgent.trim().isNotEmpty &&
      userAgent.length <= 2048 &&
      !userAgent.contains(RegExp(r'[\r\n]')) &&
      isAllowedAnubisCookieHeader(cookie) &&
      (expiresAt == null || expiresAt! > DateTime.now().millisecondsSinceEpoch);

  Map<String, Object?> toJson() => {
    'host': host,
    'cookie': cookie,
    'userAgent': userAgent,
    'expiresAt': expiresAt,
  };

  /// Proof for a host that answers without a challenge: no cookie at all.
  /// Used by the direct (no-WebView) probe path.
  factory BangumiMirrorHostProof.direct(String host) => BangumiMirrorHostProof(
    host: host,
    cookie: '',
    userAgent: kBangumiMirrorDirectUserAgent,
  );

  factory BangumiMirrorHostProof.fromJson(Map<String, dynamic> value) =>
      BangumiMirrorHostProof(
        host: value['host'] as String,
        cookie: value['cookie'] as String,
        userAgent: value['userAgent'] as String,
        expiresAt: value['expiresAt'] as int?,
      );
}

bool isAllowedAnubisCookieHeader(String header) {
  if (header.length > 16384 || header.contains(RegExp(r'[\r\n]'))) return false;
  if (header.isEmpty) return true; // The host may not require a challenge.
  return header.split(';').every((pair) {
    final split = pair.trim().indexOf('=');
    if (split < 1) return false;
    final name = pair.trim().substring(0, split);
    final value = pair.trim().substring(split + 1);
    return isBangumiAnubisCookieName(name) &&
        value.isNotEmpty &&
        value.codeUnits.every((c) => c >= 0x21 && c <= 0x7e && c != 0x3b);
  });
}

/// Exact URI authority matching prevents rewriting hosts in query strings,
/// filenames, credentials, or lookalike domains.
String normalizeBangumiCoverUrl(String raw, {required bool mirror}) {
  final uri = Uri.tryParse(raw);
  if (uri == null || !{'http', 'https'}.contains(uri.scheme)) return raw;
  if (uri.userInfo.isNotEmpty || uri.hasPort) return raw;
  if (!{
    'lain.bgm.tv',
    'bgmimg.anibt.net',
    'lain.bangumi.lat',
  }.contains(uri.host)) {
    return raw;
  }
  return uri
      .replace(
        scheme: 'https',
        host: mirror ? bangumiMirrorImageHost : 'lain.bgm.tv',
      )
      .toString();
}

typedef ConfigureMirrorProof = Future<void> Function({
  required String apiCookie,
  required String imageCookie,
  required String userAgent,
});

/// Main binds the FRB functions once after RustLib.init; this module never calls
/// generated interfaces before that initialization or invokes OAuth endpoints.
class BangumiMirrorBackend {
  final ConfigureMirrorProof configure;
  final Future<String> Function() probeApi;
  final Future<void> Function(String imageUrl) probeImage;
  final Future<void> Function(bool enabled) setEnabled;
  final Future<void> Function() clear;

  const BangumiMirrorBackend({
    required this.configure,
    required this.probeApi,
    required this.probeImage,
    required this.setEnabled,
    required this.clear,
  });
}

/// Private local preferences; configuration backup only exports its explicit
/// settings schema, and must never add this key or any proof payload.
class BangumiMirrorService extends ChangeNotifier {
  static final instance = BangumiMirrorService();
  static const proofPreferenceKey = 'bangumi_mirror_anubis_local_v1';
  BangumiMirrorService();

  @visibleForTesting
  BangumiMirrorService.withPreferences(this._preferences);

  SharedPreferences? _preferences;
  BangumiMirrorBackend? _backend;
  BangumiMirrorHostProof? _apiProof;
  BangumiMirrorHostProof? _imageProof;
  bool _enabled = false;
  bool _busy = false;
  String? _message;
  int _epoch = 0;

  bool get enabled => _enabled;
  bool get busy => _busy;
  String? get message => _message;

  void bindBackend(BangumiMirrorBackend backend) => _backend = backend;

  BangumiMirrorBackend get _bound =>
      _backend ?? (throw const BangumiMirrorException('反向代理服务尚未初始化，请稍后重试。'));

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<void> _configure(
    BangumiMirrorHostProof api,
    BangumiMirrorHostProof? image,
  ) async {
    if (!api.valid ||
        api.host != bangumiMirrorApiHost ||
        (image != null &&
            (!image.valid ||
                image.host != bangumiMirrorImageHost ||
                image.userAgent != api.userAgent))) {
      throw const BangumiMirrorException('无法读取有效且一致的反向代理验证凭据，请重新验证。');
    }
    await _bound.configure(
      apiCookie: api.cookie,
      imageCookie: image?.cookie ?? '',
      userAgent: api.userAgent,
    );
  }

  /// Startup calls this once with the requested preference. Only actual API AND
  /// image probes may restore true. Missing/expired proof never enables mirror.
  Future<bool> restore({required bool requestedEnabled}) async {
    if (_busy) return false;
    _busy = true;
    final epoch = ++_epoch;
    notifyListeners();
    try {
      await _bound.setEnabled(false);
      _enabled = false;
      if (!requestedEnabled) {
        await (await _prefs).setBool('bangumi_mirror', false);
        return false;
      }
      final raw = (await _prefs).getString(proofPreferenceKey);
      if (raw == null) throw const BangumiMirrorException('启用反向代理前需要在应用内完成验证。');
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final api = BangumiMirrorHostProof.fromJson(
        payload['api'] as Map<String, dynamic>,
      );
      final image = BangumiMirrorHostProof.fromJson(
        payload['image'] as Map<String, dynamic>,
      );
      await _configure(api, image);
      final imageUrl = await _bound.probeApi();
      await _bound.probeImage(imageUrl);
      if (epoch != _epoch) return false;
      await _bound.setEnabled(true);
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      final enabledSaved = await (await _prefs).setBool('bangumi_mirror', true);
      if (!enabledSaved) {
        throw const BangumiMirrorException('无法保存反向代理开关，已回退官方。');
      }
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      _apiProof = api;
      _imageProof = image;
      _enabled = true;
      _message = null;
      return true;
    } catch (error) {
      await _reset();
      _message = error is BangumiMirrorException
          ? error.message
          : bangumiMirrorFailureMessage;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Enable the mirror by probing it directly, without any WebView session.
  ///
  /// The live mirror API and image hosts answer plain requests with real data
  /// and no challenge, so the browser step is not normally needed. Both probes
  /// still have to pass against the real service before the mirror turns on;
  /// if either fails the caller falls back to the WebView flow, which can
  /// complete a challenge if one is being served.
  ///
  /// Returns true only when the mirror is genuinely enabled. Never throws for
  /// an unreachable mirror — that is the expected signal to fall back.
  Future<bool> enableDirect() async {
    if (_busy) return false;
    _busy = true;
    final epoch = ++_epoch;
    notifyListeners();
    try {
      await _reset();
      final api = BangumiMirrorHostProof.direct(bangumiMirrorApiHost);
      final image = BangumiMirrorHostProof.direct(bangumiMirrorImageHost);
      await _configure(api, image);
      final imageUrl = await _bound.probeApi();
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      await _bound.probeImage(imageUrl);
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      // Persist before enabling: a failed write must not leave the mirror on
      // with nothing to restore at next startup.
      final saved = await (await _prefs).setString(
        proofPreferenceKey,
        jsonEncode({'api': api.toJson(), 'image': image.toJson()}),
      );
      if (!saved) {
        await _reset();
        return false;
      }
      await _bound.setEnabled(true);
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      final enabledSaved = await (await _prefs).setBool('bangumi_mirror', true);
      if (!enabledSaved) {
        await _reset();
        return false;
      }
      if (epoch != _epoch) {
        await _reset();
        return false;
      }
      _apiProof = api;
      _imageProof = image;
      _enabled = true;
      _message = null;
      return true;
    } catch (_) {
      // Any failure (challenge served, network blocked, bad payload) simply
      // means the direct path is not usable right now.
      await _reset();
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> verifyAndEnable(
    BuildContext context, {
    MirrorWebHostFactory? hostFactory,
  }) async {
    if (_busy) return false;
    _busy = true;
    final epoch = ++_epoch;
    _message = null;
    notifyListeners();
    try {
      await _reset();
      if (!context.mounted) return false;
      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => BangumiMirrorVerificationPage(
            hostFactory: hostFactory,
            onApiProof: (api) async {
              if (epoch != _epoch) {
                throw const BangumiMirrorException('反向代理验证已取消。');
              }
              await _configure(api, null);
              final imageUrl = await _bound.probeApi();
              if (epoch != _epoch) {
                throw const BangumiMirrorException('反向代理验证已取消。');
              }
              _apiProof = api;
              return imageUrl;
            },
            onImageProof: (image, imageUrl) async {
              try {
                final api = _apiProof;
                if (api == null) {
                  throw const BangumiMirrorException('请先完成 API 验证。');
                }
                if (epoch != _epoch) {
                  throw const BangumiMirrorException('反向代理验证已取消。');
                }
                await _configure(api, image);
                await _bound.probeImage(imageUrl);
                if (epoch != _epoch) {
                  throw const BangumiMirrorException('反向代理验证已取消。');
                }
                // Persistence precedes enabling; a failed disk write never leaves
                // the Rust mirror enabled with no restorable local credentials.
                final saved = await (await _prefs).setString(
                  proofPreferenceKey,
                  jsonEncode({'api': api.toJson(), 'image': image.toJson()}),
                );
                if (!saved) {
                  throw const BangumiMirrorException('无法保存反向代理验证，请关闭反向代理回退官方。');
                }
                if (epoch != _epoch) {
                  throw const BangumiMirrorException('反向代理验证已取消。');
                }
                await _bound.setEnabled(true);
                if (epoch != _epoch) {
                  await _reset();
                  throw const BangumiMirrorException('反向代理验证已取消。');
                }
                final enabledSaved = await (await _prefs).setBool(
                  'bangumi_mirror',
                  true,
                );
                if (!enabledSaved) {
                  throw const BangumiMirrorException('无法保存反向代理开关，已回退官方。');
                }
                if (epoch != _epoch) {
                  await _reset();
                  throw const BangumiMirrorException('反向代理验证已取消。');
                }
                _imageProof = image;
                _enabled = true;
              } catch (error) {
                // Do not leave Rust enabled after a final preference/bridge
                // failure. Keep the API proof only to permit a page retry.
                _enabled = false;
                _imageProof = null;
                await _bound.setEnabled(false);
                await (await _prefs).setBool('bangumi_mirror', false);
                await (await _prefs).remove(proofPreferenceKey);
                rethrow;
              }
            },
          ),
        ),
      );
      if (result != true || !_enabled) {
        await _reset();
        return false;
      }
      return true;
    } catch (error) {
      await _reset();
      _message = error is BangumiMirrorException
          ? error.message
          : bangumiMirrorFailureMessage;
      throw BangumiMirrorException(_message!);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _reset() async {
    _enabled = false;
    _apiProof = null;
    _imageProof = null;
    // Turn off Rust before disk I/O; storage failure must not leave requests
    // using mirror credentials while the UI says disabled.
    await _bound.setEnabled(false);
    await _bound.clear();
    await (await _prefs).setBool('bangumi_mirror', false);
  }

  Future<void> disable() async {
    ++_epoch;
    await _reset();
    await (await _prefs).remove(proofPreferenceKey);
    notifyListeners();
  }

  /// Mirror credentials are never sent to official or arbitrary image hosts.
  Map<String, String> headersForCover(String url) {
    final uri = Uri.tryParse(url);
    final proof = _imageProof;
    if (!_enabled ||
        uri?.scheme != 'https' ||
        uri?.host != bangumiMirrorImageHost ||
        uri!.userInfo.isNotEmpty ||
        uri.hasPort ||
        proof == null ||
        !proof.valid) {
      return const {'User-Agent': 'Kurako/1.0', 'Referer': 'https://bgm.tv/'};
    }
    return {
      'User-Agent': proof.userAgent,
      if (proof.cookie.isNotEmpty) 'Cookie': proof.cookie,
    };
  }

  /// Notify outside the current widget build; settings can watch this service
  /// to expose the common reverify/disable entry rather than one dialog per cover.
  void reportApiFailure(Object error) {
    if (!_enabled) return;
    // Only classify the marker; never display/log the raw bridge exception.
    if (error.toString().contains('Bangumi 反向代理验证') ||
        error.toString().contains('bangumi mirror')) {
      reportCoverFailure();
    }
  }

  void reportCoverFailure() {
    if (!_enabled || _message != null) return;
    _message = bangumiMirrorFailureMessage;
    Future.microtask(notifyListeners);
  }
}

class BangumiMirrorException implements Exception {
  final String message;
  const BangumiMirrorException(this.message);
  @override
  String toString() => message;
}
