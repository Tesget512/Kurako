import 'package:flutter_test/flutter_test.dart';
import 'package:kurako/src/state/episode_title_marks.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('marks persist per anime and episode and merge on add', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await EpisodeTitleMarks.load(), isEmpty);

    await EpisodeTitleMarks.add({EpisodeTitleMarks.keyFor(4, 1)});
    await EpisodeTitleMarks.add({
      EpisodeTitleMarks.keyFor(4, 2),
      EpisodeTitleMarks.keyFor(4, 1),
    });

    final marked = await EpisodeTitleMarks.load();
    expect(marked, {'4:1', '4:2'});
    // An episode added later is not covered by earlier marks.
    expect(marked.contains(EpisodeTitleMarks.keyFor(4, 3)), isFalse);
    expect(marked.contains(EpisodeTitleMarks.keyFor(5, 1)), isFalse);
  });
}
