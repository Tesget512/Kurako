import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/bangumi_oauth.dart';

void main() {
  const callback = 'kurako://oauth/callback';

  String parse(String url, {String state = 'expected'}) =>
      parseBangumiOAuthCode(url, expectedState: state);

  test('Bangumi OAuth callback returns the code for the expected state', () {
    expect(
      parse('$callback?code=one-time-code&state=expected'),
      'one-time-code',
    );
  });

  test('Bangumi OAuth callback rejects a mismatched or missing state', () {
    for (final url in [
      '$callback?code=one-time-code&state=unexpected',
      '$callback?code=one-time-code',
    ]) {
      expect(() => parse(url), throwsA(isA<OAuthException>()), reason: url);
    }
    // An empty expected state can never match anything.
    expect(
      () => parseBangumiOAuthCode('$callback?code=c', expectedState: ''),
      throwsA(isA<OAuthException>()),
    );
  });

  test('Bangumi OAuth callback rejects another custom-protocol path', () {
    for (final url in [
      'kurako://oauth/other?code=one-time-code&state=expected',
      'kurako://oauth/callback/extra?code=one-time-code&state=expected',
      'kurako://oauth?code=one-time-code&state=expected',
      'kurako://other/callback?code=one-time-code&state=expected',
      // Not the registered scheme/host at all.
      'https://oauth/callback?code=one-time-code&state=expected',
      // userinfo, port and fragment are never part of the registered callback.
      'kurako://user@oauth/callback?code=one-time-code&state=expected',
      'kurako://oauth:8080/callback?code=one-time-code&state=expected',
      '$callback?code=one-time-code&state=expected#fragment',
    ]) {
      expect(() => parse(url), throwsA(isA<OAuthException>()), reason: url);
    }
  });

  test('duplicated parameters are rejected instead of silently resolved', () {
    for (final url in [
      '$callback?code=one&code=two&state=expected',
      '$callback?code=one&state=expected&state=other',
      '$callback?code=one&state=expected&error=access_denied',
      '$callback?error=access_denied&error=access_denied&state=expected',
    ]) {
      expect(() => parse(url), throwsA(isA<OAuthException>()), reason: url);
    }
  });

  test('provider errors are reported without echoing provider text', () {
    expect(
      () => parse('$callback?error=access_denied&state=expected'),
      throwsA(
        isA<OAuthException>().having(
          (error) => error.message,
          'message',
          contains('access_denied'),
        ),
      ),
    );
    // A provider-authored description must not reach the user.
    expect(
      () => parse(
        '$callback?error=access_denied&error_description=server+said+secret&state=expected',
      ),
      throwsA(
        isA<OAuthException>().having(
          (error) => error.message,
          'message',
          isNot(contains('secret')),
        ),
      ),
    );
  });

  test('a blank or absent code is rejected', () {
    for (final url in [
      '$callback?state=expected',
      '$callback?code=&state=expected',
      '$callback?code=%20%20&state=expected',
    ]) {
      expect(() => parse(url), throwsA(isA<OAuthException>()), reason: url);
    }
  });

  test('state is checked before the code or provider error is read', () {
    // A forged callback with a bad state must not even reveal that the code
    // was fine or that the provider reported an error.
    expect(
      () => parse('$callback?code=one&state=wrong'),
      throwsA(
        isA<OAuthException>().having(
          (error) => error.message,
          'message',
          contains('状态校验失败'),
        ),
      ),
    );
  });

  test('login failures map to safe, actionable reasons', () {
    // Rust reports allowlisted codes; the mapping must recognise them.
    expect(
      bangumiLoginFailureMessage(Exception('oauth error: invalid_grant')),
      contains('过期或已使用'),
    );
    expect(
      bangumiLoginFailureMessage(Exception('oauth error: invalid_client')),
      contains('应用授权配置'),
    );
    expect(
      bangumiLoginFailureMessage(Exception('oauth error: invalid_request')),
      contains('授权请求'),
    );
    expect(
      bangumiLoginFailureMessage(Exception('oauth token verification failed')),
      contains('验证失败'),
    );
    expect(
      bangumiLoginFailureMessage(Exception('oauth response invalid JSON')),
      contains('未返回有效数据'),
    );
    expect(
      bangumiLoginFailureMessage(Exception('oauth request http 502')),
      contains('返回错误'),
    );
    // Unknown/transport failures fall back to a network hint.
    expect(
      bangumiLoginFailureMessage(Exception('oauth token request failed')),
      contains('网络'),
    );
    // An OAuthException keeps its own precise message.
    expect(
      bangumiLoginFailureMessage(const OAuthException('已取消 Bangumi 授权。')),
      '已取消 Bangumi 授权。',
    );
    // Server-authored text must never be surfaced verbatim.
    expect(
      bangumiLoginFailureMessage(Exception('boom secret-token-value')),
      isNot(contains('secret-token-value')),
    );
  });
}
