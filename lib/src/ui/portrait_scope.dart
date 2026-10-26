import 'package:material_ui/material_ui.dart';

class PortraitPreviewScope extends InheritedWidget {
  const PortraitPreviewScope({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PortraitPreviewScope>()
          ?.enabled ??
      false;
  @override
  bool updateShouldNotify(PortraitPreviewScope oldWidget) =>
      enabled != oldWidget.enabled;
}
