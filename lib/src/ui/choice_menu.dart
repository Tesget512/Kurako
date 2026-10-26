import 'package:material_ui/material_ui.dart';

class ChoiceMenu<T> extends StatelessWidget {
  const ChoiceMenu({
    super.key,
    required this.value,
    required this.choices,
    required this.onSelected,
  });
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      maximumSize: const WidgetStatePropertyAll(Size(320, 400)),
    ),
    menuChildren: [
      for (final entry in choices.entries)
        MenuItemButton(
          leadingIcon: Icon(value == entry.key ? Icons.check : null, size: 20),
          onPressed: () => onSelected(entry.key),
          child: Text(entry.value),
        ),
    ],
    builder: (context, controller, _) => TextButton(
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(choices[value] ?? '', overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.expand_more, size: 20),
        ],
      ),
    ),
  );
}
