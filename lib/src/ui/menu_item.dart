import 'package:material_ui/material_ui.dart';

ButtonStyle kurakoMenuItemStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? scheme.secondaryContainer
          : null,
    ),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.pressed)
          ? scheme.onSurface.withValues(alpha: 0.12)
          : states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
          ? scheme.onSurface.withValues(alpha: 0.08)
          : null,
    ),
  );
}

/// The ink needs its own clipped surface, not just a rounded menu outline.
class KurakoPopupMenuItem<T> extends PopupMenuItem<T> {
  const KurakoPopupMenuItem({
    super.key,
    super.value,
    super.enabled,
    super.padding,
    required super.child,
  });

  @override
  PopupMenuItemState<T, KurakoPopupMenuItem<T>> createState() =>
      _KurakoPopupMenuItemState<T>();
}

class _KurakoPopupMenuItemState<T>
    extends PopupMenuItemState<T, KurakoPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: super.build(context),
    ),
  );
}

class KurakoCheckedMenuItem<T> extends CheckedPopupMenuItem<T> {
  const KurakoCheckedMenuItem({
    super.key,
    super.value,
    super.checked,
    required super.child,
  });

  @override
  PopupMenuItemState<T, CheckedPopupMenuItem<T>> createState() =>
      _KurakoCheckedMenuItemState<T>();
}

class _KurakoCheckedMenuItemState<T>
    extends PopupMenuItemState<T, CheckedPopupMenuItem<T>> {
  @override
  Widget buildChild() => Row(
    children: [
      Icon(widget.checked ? Icons.check_rounded : null, size: 20),
      const SizedBox(width: 12),
      Expanded(child: widget.child ?? const SizedBox.shrink()),
    ],
  );

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: super.build(context),
  );
}
