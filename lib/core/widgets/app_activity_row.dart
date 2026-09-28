import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/features/homes/domain/household_event.dart';

/// One coherent row for a [HouseholdEvent], shared by the Household
/// Dashboard's "Recent activity" preview and the full Activity screen.
///
/// Both previously rendered the same feed two different ways: the dashboard
/// had an event icon and a relative-time label, the full screen had neither
/// an icon nor a fallback to an absolute date for old events. This is the
/// union of the two — icon always shown (meaning is never colour-only), the
/// more complete relative-time formatting always used.
///
/// Content-layer only: no card, no feature-coloured background, no blur.
class AppActivityRow extends StatelessWidget {
  const AppActivityRow({super.key, required this.event, this.dense = false});

  final HouseholdEvent event;

  /// Tighter row padding for the dashboard's embedded preview list. The full
  /// Activity screen uses the default (false).
  final bool dense;

  static IconData _iconForEventType(String eventType) {
    return switch (eventType) {
      'task_created' => Icons.add_task_rounded,
      // No rounded variant exists for this specific glyph — already reads
      // as a solid, rounded-enough icon in the current set.
      'task_completed' => Icons.task_alt,
      'task_reopened' => Icons.replay_rounded,
      'task_deleted' => Icons.delete_outline_rounded,
      'shopping_item_added' => Icons.add_shopping_cart_rounded,
      'shopping_item_completed' => Icons.shopping_cart_checkout_rounded,
      'shopping_item_reopened' => Icons.replay_rounded,
      'expense_created' => Icons.receipt_long_rounded,
      'expense_deleted' => Icons.receipt_long_rounded,
      'member_joined' => Icons.person_add_rounded,
      'member_left' => Icons.person_remove_rounded,
      'member_removed' => Icons.person_off_rounded,
      'ownership_transferred' => Icons.admin_panel_settings_rounded,
      _ => Icons.circle_outlined,
    };
  }

  static String _relativeTime(DateTime utc) {
    final local = utc.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListTile(
      leading: Icon(
        _iconForEventType(event.eventType),
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
      // No maxLines/overflow: long task/member/household names wrap onto a
      // second line rather than clipping, at any text scale.
      title: Text(event.displayText, style: textTheme.bodyMedium),
      subtitle: Text(
        _relativeTime(event.occurredAt),
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
      dense: dense,
      minVerticalPadding: AppSpacing.xs,
    );
  }
}
