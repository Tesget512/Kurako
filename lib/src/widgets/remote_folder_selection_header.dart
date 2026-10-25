import 'package:material_ui/material_ui.dart';

/// A persistent path row for remote-folder pickers. The confirmation action
/// stays above the scrolling directory contents instead of living at the end of
/// a potentially very long server listing.
class RemoteFolderSelectionHeader extends StatelessWidget {
  final List<Widget> breadcrumbs;
  final int selectedCount;
  final VoidCallback? onConfirm;

  const RemoteFolderSelectionHeader({
    super.key,
    required this.breadcrumbs,
    required this.selectedCount,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final action = FilledButton.icon(
          onPressed: onConfirm,
          icon: const Icon(Icons.add),
          label: Text(
            compact ? '添加 ($selectedCount)' : '添加 $selectedCount 个文件夹',
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < breadcrumbs.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 4),
                      breadcrumbs[index],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            action,
          ],
        );
      },
    );
  }
}
