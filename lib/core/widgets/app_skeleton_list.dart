import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A quiet skeleton loading placeholder for lists of row-shaped content.
///
/// Extracted from Today's original loading state, which was the only screen
/// with a real loading treatment — every other list screen used a bare
/// [CircularProgressIndicator]. Pass [sectionCounts] as the number of
/// skeleton rows under each section label, e.g. `{'Today': 3, 'Upcoming': 2}`.
/// Use the empty string as a key to render a group of rows with no section
/// label — for flat lists (e.g. Tasks) that don't group by section.
///
/// Placed directly in a `Scaffold.body` it owns the screen's scrolling. If it
/// is ever embedded in a host that already scrolls, pass `scrollable: false`
/// so there is still exactly one scroll owner.
class AppSkeletonList extends StatelessWidget {
  const AppSkeletonList({
    super.key,
    required this.sectionCounts,
    this.scrollable = true,
  });

  final Map<String, int> sectionCounts;

  /// Whether this widget provides its own scrolling. Set to `false` when it
  /// sits inside a scroll view that the host screen already owns.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.12);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in sectionCounts.entries) ...[
          if (entry.key.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.base,
                AppSpacing.lg,
                AppSpacing.base,
                AppSpacing.sm,
              ),
              child: Text(
                entry.key,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ..._skeletonTiles(color, entry.value),
        ],
      ],
    );

    if (!scrollable) return content;

    // A plain scroll view rather than a ListView: the rows are a fixed, tiny
    // set, so lazy building buys nothing, and being scrollable (instead of the
    // previous NeverScrollableScrollPhysics) means the placeholder can be
    // reached rather than silently clipped on a short viewport or at a large
    // text scale. SafeArea keeps the last row clear of the shell's nav bar.
    return SingleChildScrollView(child: SafeArea(top: false, child: content));
  }

  List<Widget> _skeletonTiles(Color color, int count) {
    return List.generate(
      count,
      (i) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.base,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 14,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    height: 11,
                    width: 120,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
