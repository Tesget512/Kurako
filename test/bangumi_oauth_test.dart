import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/services/bangumi_oauth.dart';

void main() {
  test('Bangumi OAuth callback returns the code for the expected state', () {
    expect(
      parseBangumiOAuthCode(
        'kurako://oauth/callback?code=one-time-code&state=expected',
        expectedState: 'expected',
      ),
      'one-time-code',
    );
  });

  test('Bangumi OAuth callback rejects a mismatched state', () {
    expect(
      () => parseBangumiOAuthCode(
        'kurako://oauth/callback?code=one-time-code&state=unexpected',
        expectedState: 'expected',
      ),
      throwsA(isA<OAuthException>()),
    );
  });

  test('Bangumi OAuth callback rejects another custom-protocol path', () {
    expect(
      () => parseBangumiOAuthCode(
        'kurako://oauth/other?code=one-time-code&state=expected',
        expectedState: 'expected',
      ),
      throwsA(isA<OAuthException>()),
    );
  });

  test('Bangumi OAuth callback reports provider errors', () {
    expect(
      () => parseBangumiOAuthCode(
        'kurako://oauth/callback?error=access_denied&state=expected',
        expectedState: 'expected',
      ),
      throwsA(
        isA<OAuthException>().having(
          (error) => error.message,
          'message',
          contains('access_denied'),
        ),
      ),
    );
  });
}
