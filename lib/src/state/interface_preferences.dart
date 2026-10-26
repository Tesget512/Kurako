import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum InterfaceOption {
  searchExpanded(false),
  posterProgress(true),
  posterRating(true),
  posterBadge(true),
  playerSideTools(true);

  const InterfaceOption(this.defaultValue);
  final bool defaultValue;
  String get key => 'interface_$name';
}

enum PosterSize {
  compact(180),
  standard(220),
  large(280);

  const PosterSize(this.extent);
  final double extent;
}

class InterfacePreferences {
  const InterfacePreferences({
    this.values = const {},
    this.posterSize = PosterSize.standard,
  });
  final Map<InterfaceOption, bool> values;
  final PosterSize posterSize;
  bool enabled(InterfaceOption option) => values[option] ?? option.defaultValue;
}

final interfacePreferencesProvider =
    NotifierProvider<InterfacePreferencesNotifier, InterfacePreferences>(
      InterfacePreferencesNotifier.new,
    );

class InterfacePreferencesNotifier extends Notifier<InterfacePreferences> {
  late Future<void> ready;
  Future<void> _writes = Future<void>.value();

  @override
  InterfacePreferences build() {
    ready = _load();
    return const InterfacePreferences();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final size = prefs.getString('interface_poster_size');
    state = InterfacePreferences(
      values: {
        for (final option in InterfaceOption.values)
          option: prefs.getBool(option.key) ?? option.defaultValue,
      },
      posterSize: PosterSize.values.firstWhere(
        (value) => value.name == size,
        orElse: () => PosterSize.standard,
      ),
    );
  }

  Future<void> _write(Future<void> Function(SharedPreferences) action) {
    final operation = _writes.then((_) async {
      await ready;
      if (!ref.mounted) return;
      await action(await SharedPreferences.getInstance());
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setOption(InterfaceOption option, bool value) =>
      _write((prefs) async {
        await prefs.setBool(option.key, value);
        if (!ref.mounted) return;
        state = InterfacePreferences(
          values: {...state.values, option: value},
          posterSize: state.posterSize,
        );
      });

  Future<void> setPosterSize(PosterSize size) => _write((prefs) async {
    await prefs.setString('interface_poster_size', size.name);
    if (!ref.mounted) return;
    state = InterfacePreferences(values: state.values, posterSize: size);
  });
}
