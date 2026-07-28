import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/pages/webdav_source_wizard.dart';
import 'package:kurako/src/services/remote_path_selection.dart';

void main() {
  test('normalizes safe WebDAV roots and rejects embedded credentials', () {
    expect(
      normalizeWebDavAddress('https://dav.example.test/root'),
      'https://dav.example.test/root/',
    );
    expect(normalizeWebDavAddress('ftp://dav.example.test/root'), isNull);
    expect(
      normalizeWebDavAddress('https://user:pass@dav.example.test/root'),
      isNull,
    );
  });

  test('source root comparison observes path boundaries', () {
    const base = 'https://dav.example.test/root/';
    expect(webDavSourceBelongsToBase('$base/Anime', base), isTrue);
    expect(
      webDavSourceBelongsToBase('https://dav.example.test/root2/Anime', base),
      isFalse,
    );
  });

  test('multi-selection removes children covered by a selected parent', () {
    expect(compactSelectedRemotePaths(['Anime', 'Anime/Season 1', 'Movies']), {
      'Anime',
      'Movies',
    });
  });
}
