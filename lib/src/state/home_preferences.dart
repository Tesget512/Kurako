import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const homePreferencesKey = 'home_preferences';

enum AppDestination { home, library, collection, settings }

enum HomeModule { resume, watching, wish }

class HomePreferences {
  const HomePreferences({
    this.enabled = true,
    this.initial = AppDestination.library,
    this.modules = const [
      HomeModule.resume,
      HomeModule.watching,
      HomeModule.wish,
    ],
    this.hidden = const {HomeModule.wish},
    this.loaded = false,
  });
  final bool enabled, loaded;
  final AppDestination initial;
  final List<HomeModule> modules;
  final Set<HomeModule> hidden;

  HomePreferences copyWith({
    bool? enabled,
    AppDestination? initial,
    List<HomeModule>? modules,
    Set<HomeModule>? hidden,
    bool? loaded,
  }) {
    final showHome = enabled ?? this.enabled;
    final start = initial ?? this.initial;
    return HomePreferences(
      enabled: showHome,
      initial: !showHome && start == AppDestination.home
          ? AppDestination.library
          : start,
      modules: List.unmodifiable(modules ?? this.modules),
      hidden: Set.unmodifiable(hidden ?? this.hidden),
      loaded: loaded ?? this.loaded,
    );
  }

  String encode() => jsonEncode({
    'enabled': enabled,
    'initial': initial.name,
    'modules': modules.map((m) => m.name).toList(),
    'hidden': hidden.map((m) => m.name).toList(),
  });
  static HomePreferences decode(String source) {
    final Object? data = jsonDecode(source);
    if (data is! Map ||
        data.length != 4 ||
        data['enabled'] is! bool ||
        !AppDestination.values.any((v) => v.name == data['initial']) ||
        data['modules'] is! List ||
        data['hidden'] is! List) {
      throw const FormatException('首页配置格式无效');
    }
    final order = data['modules'] as List;
    final hidden = data['hidden'] as List;
    final names = HomeModule.values.map((m) => m.name).toSet();
    final legacy =
        order.length == 2 && order.toSet().containsAll({'resume', 'watching'});
    if ((!legacy && order.length != names.length) ||
        order.toSet().length != order.length ||
        !names.containsAll(order) ||
        hidden.length > names.length ||
        hidden.toSet().length != hidden.length ||
        !order.toSet().containsAll(hidden)) {
      throw const FormatException('首页模块配置无效');
    }
    return HomePreferences(
      enabled: data['enabled'] as bool,
      initial: AppDestination.values.byName(data['initial'] as String),
      modules: [
        ...order.map((m) => HomeModule.values.byName(m as String)),
        if (legacy) HomeModule.wish,
      ],
      hidden: {
        ...hidden.map((m) => HomeModule.values.byName(m as String)),
        if (legacy) HomeModule.wish,
      },
      loaded: true,
    ).copyWith();
  }
}

bool validHomePreferences(Object value) {
  if (value is! String || value.length > 2048) return false;
  try {
    HomePreferences.decode(value);
    return true;
  } catch (_) {
    return false;
  }
}

final homePreferencesProvider =
    NotifierProvider<HomePreferencesNotifier, HomePreferences>(
      HomePreferencesNotifier.new,
    );

class HomePreferencesNotifier extends Notifier<HomePreferences> {
  late Future<void> ready;
  Future<void> _writes = Future.value();
  @override
  HomePreferences build() {
    ready = _load();
    return const HomePreferences();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var value = const HomePreferences(loaded: true);
    final raw = prefs.get(homePreferencesKey);
    if (raw is String && validHomePreferences(raw)) {
      value = HomePreferences.decode(raw);
    }
    if (ref.mounted) state = value;
  }

  Future<void> _update(HomePreferences Function(HomePreferences) transform) {
    final operation = _writes.then((_) async {
      await ready;
      if (!ref.mounted) return;
      final value = transform(state);
      if (!await (await SharedPreferences.getInstance()).setString(
        homePreferencesKey,
        value.encode(),
      )) {
        throw StateError('首页配置保存失败');
      }
      if (ref.mounted) state = value;
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setEnabled(bool value) =>
      _update((s) => s.copyWith(enabled: value));
  Future<void> setInitial(AppDestination value) =>
      _update((s) => s.copyWith(initial: value));
  Future<void> show(HomeModule module, bool value) => _update(
    (s) => s.copyWith(
      hidden: {...s.hidden}
        ..removeWhere((m) => m == module)
        ..addAll(value ? <HomeModule>[] : [module]),
    ),
  );
  Future<void> move(HomeModule module, int delta) => _update((s) {
    final items = [...s.modules];
    final index = items.indexOf(module);
    final target = (index + delta).clamp(0, items.length - 1);
    items.removeAt(index);
    items.insert(target, module);
    return s.copyWith(modules: items);
  });
  Future<void> reset() => _update((_) => const HomePreferences(loaded: true));
}
