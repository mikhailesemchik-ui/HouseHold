import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A calm, understated empty state for lists and screens.
///
/// Supply [actionLabel] and [onAction] together for an *actionable* empty
/// state (nothing exists yet and the user should create something). Leave them
/// off for an *informational* one (nothing needs doing — e.g. Today with no
/// assigned tasks). Not every empty state deserves a call to action.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.alignment = Alignment.center,
    this.actionLabel,
    this.onAction,
  }) : assert(
         (actionLabel == null) == (onAction == null),
         'Provide both actionLabel and onAction, or neither.',
       );

  /// Omit for a quiet, icon-less empty state (e.g. Shopping, per the v2
  /// handoff's "no illustration" rule).
  final IconData? icon;
  final String title;
  final String? subtitle;

  /// Controls vertical placement within the available space.
  /// Defaults to centered. Pass e.g. [Alignment(0, -0.3)] to position
  /// slightly above center for full-screen empty states.
  final Alignment alignment;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 36,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(
              title,
              style: textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: AppSpacing.base),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
