import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Shared reading measure for settings and utility pages, using local width.
class KurakoPageList extends StatelessWidget {
  const KurakoPageList({
    super.key,
    required this.children,
    this.maxWidth = 1000,
    this.centerContent = false,
  });

  final List<Widget> children;
  final double maxWidth;
  final bool centerContent;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final gutter = constraints.maxWidth < 600 ? 16.0 : 28.0;
      final inset = math.max(gutter, (constraints.maxWidth - maxWidth) / 2);
      if (centerContent) {
        final top = 20 + MediaQuery.paddingOf(context).top;
        final bottom = 32 + MediaQuery.paddingOf(context).bottom;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(inset, top, inset, bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - top - bottom),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        );
      }
      return ListView(
        padding: EdgeInsets.fromLTRB(
          inset,
          20 + MediaQuery.paddingOf(context).top,
          inset,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: children,
      );
    },
  );
}

class KurakoContent extends StatelessWidget {
  const KurakoContent({super.key, required this.child, this.maxWidth = 1000});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

class KurakoPageHeader extends StatelessWidget {
  const KurakoPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      icon,
                      size: 28,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  title,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 16), trailing!],
        ],
      ),
    );
  }
}

class KurakoSectionHeading extends StatelessWidget {
  const KurakoSectionHeading({
    super.key,
    required this.title,
    this.count,
    this.trailing,
  });
  final String title;
  final String? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Flexible(child: Text(title, style: theme.textTheme.titleLarge)),
          if (count != null) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: ShapeDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: const StadiumBorder(),
              ),
              child: Text(
                count!,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
          if (trailing != null) ...[
            const Spacer(),
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class KurakoEmptyState extends StatelessWidget {
  const KurakoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Icon(
                  icon,
                  size: 40,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              if (description != null) ...[
                const SizedBox(height: 10),
                Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 24), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Wrap, not a fixed-aspect grid: translated text and larger fonts can grow.
class KurakoCardGrid extends StatelessWidget {
  const KurakoCardGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900
          ? 3
          : constraints.maxWidth >= 560
          ? 2
          : 1;
      final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
