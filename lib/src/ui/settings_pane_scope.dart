import 'package:material_ui/material_ui.dart';

class SettingsPaneScope extends InheritedWidget {
  const SettingsPaneScope({super.key, required super.child});
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsPaneScope>() != null;
  @override
  bool updateShouldNotify(SettingsPaneScope oldWidget) => false;
}
