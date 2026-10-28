import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which episodes were already looked up on Bangumi and still came
/// back without a title, so opening a detail page does not refetch the same
/// show forever. A mark is written only after a refresh succeeded; a network
/// failure leaves the episode unmarked and it is retried on a later run.
class EpisodeTitleMarks {
  const EpisodeTitleMarks._();

  static const _key = 'episode_title_checked_v1';

  static String keyFor(int animeId, int episodeNo) => '$animeId:$episodeNo';

  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  static Future<void> add(Iterable<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    final all = (prefs.getStringList(_key) ?? const <String>[]).toSet()
      ..addAll(keys);
    await prefs.setStringList(_key, all.toList()..sort());
  }
}
