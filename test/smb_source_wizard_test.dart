import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/pages/smb_source_wizard.dart';

void main() {
  test('SMB 多选目录会去除父子重复但保留兄弟目录', () {
    expect(
      compactSelectedSmbPaths([
        'Anime',
        'Anime/Series A',
        'Movies/Anime',
        'Movies/Live Action',
      ]),
      {'Anime', 'Movies/Anime', 'Movies/Live Action'},
    );
  });

  test('选择共享根目录后不重复添加任何子目录', () {
    expect(compactSelectedSmbPaths(['', 'Anime', '/Movies/']), {''});
  });
}
