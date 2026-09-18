import 'package:flutter/material.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A consistent section label used across Today, the Dashboard, and Shopping.
/// [isWarning] adds an overdue-style icon and uses the error color.
///
/// [trailing], when supplied, is an action aligned to the far end of the
/// header (e.g. Shopping's "Clear completed"). The label and trailing action
/// wrap onto separate lines instead of overflowing when both can't fit at a
/// large text scale — no fixed height, nothing is clipped.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.label,
    this.isWarning = false,
    this.trailing,
  });

  final String label;
  final bool isWarning;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = isWarning ? colorScheme.error : colorScheme.onSurfaceVariant;

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isWarning) ...[
          Icon(Icons.schedule_outlined, size: 13, color: color),
          const SizedBox(width: AppSpacing.xs),
        ],
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.eyebrow?.copyWith(color: color),
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.base,
        AppSpacing.lg,
        // Shopping's "Clear completed" already carries its own horizontal
        // padding as a TextButton — a smaller right gutter here matches its
        // prior standalone layout.
        trailing == null ? AppSpacing.base : AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: trailing == null
          ? title
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: AppSpacing.xs,
              children: [title, trailing!],
            ),
    );
  }
}
