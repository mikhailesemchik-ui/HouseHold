import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/homes/data/household_stats_repository.dart';
import 'package:household_os/features/homes/domain/household_stats.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';

class StatisticsScreen extends ConsumerStatefulWidget {
  const StatisticsScreen({
    super.key,
    required this.householdId,
    this.applySuggestionOverride,
  });

  final String householdId;
  final Future<void> Function(TaskRotationSuggestion suggestion)?
  applySuggestionOverride;

  @override
  ConsumerState<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends ConsumerState<StatisticsScreen> {
  HouseholdStatsPeriod _period = HouseholdStatsPeriod.last30Days;
  final _dismissedSuggestionTaskIds = <String>{};
  final _applyingSuggestionTaskIds = <String>{};

  Future<void> _applySuggestion(TaskRotationSuggestion suggestion) async {
    if (_applyingSuggestionTaskIds.contains(suggestion.taskId)) return;
    setState(() => _applyingSuggestionTaskIds.add(suggestion.taskId));
    try {
      final applySuggestion = widget.applySuggestionOverride;
      if (applySuggestion != null) {
        await applySuggestion(suggestion);
      } else {
        await HouseholdStatsRepository(
          supabaseClient,
        ).applyRotationSuggestion(suggestion);
      }
      if (!mounted) return;
      setState(() => _dismissedSuggestionTaskIds.add(suggestion.taskId));
      ref.invalidate(taskRotationSuggestionsProvider(widget.householdId));
      ref.invalidate(
        householdStatsProvider(
          HouseholdStatsRequest(
            householdId: widget.householdId,
            period: _period,
          ),
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rotation suggestion applied.')),
      );
    } catch (_) {
      if (!mounted) return;
      ref.invalidate(taskRotationSuggestionsProvider(widget.householdId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not apply suggestion. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _applyingSuggestionTaskIds.remove(suggestion.taskId));
      }
    }
  }

  void _keepCurrent(TaskRotationSuggestion suggestion) {
    setState(() => _dismissedSuggestionTaskIds.add(suggestion.taskId));
  }

  @override
  Widget build(BuildContext context) {
    final request = HouseholdStatsRequest(
      householdId: widget.householdId,
      period: _period,
    );
    final statsAsync = ref.watch(householdStatsProvider(request));
    final suggestionsAsync = ref.watch(
      taskRotationSuggestionsProvider(widget.householdId),
    );

    // The header is ordinary scrollable content now (not a pinned `AppBar`)
    // — every branch below places it as the first item of its own
    // scrollable, unpadded (matching the AppBar's own edge-to-edge
    // geometry), so it scrolls away with the page and returns naturally at
    // the top.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Statistics',
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: statsAsync.when(
          loading: () => ListView(
            children: const [
              header,
              AppSkeletonList(sectionCounts: {'': 4}, scrollable: false),
            ],
          ),
          error: (_, _) => ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load statistics. Please try again.',
                onRetry: () => ref.invalidate(householdStatsProvider(request)),
              ),
            ],
          ),
          data: (stats) {
            return ListView(
              // The header must stay unpadded (flush, matching the AppBar's
              // own edge-to-edge geometry) — so the content's horizontal/
              // bottom insets live on the inner `Padding` below instead of
              // here, and this outer list opts out of auto-consuming
              // MediaQuery itself to avoid double-counting the nav
              // clearance the inner Padding already applies explicitly.
              padding: EdgeInsets.zero,
              children: [
                header,
                Padding(
                  key: const ValueKey('statisticsContentPadding'),
                  // Explicit padding (needed for the horizontal insets)
                  // opts out of automatic MediaQuery consumption — without
                  // re-applying the nav clearance here the last section
                  // sits under the glass nav bar.
                  padding: EdgeInsets.only(
                    left: AppSpacing.base,
                    right: AppSpacing.base,
                    top: AppSpacing.md,
                    bottom: context.shellBottomInset + AppSpacing.md,
                  ),
                  child: Column(
                    children: [
                      _PeriodSelector(
                        selected: _period,
                        onChanged: (period) => setState(() => _period = period),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _StatisticsHero(stats: stats),
                      const SizedBox(height: AppSpacing.lg),
                      _MemberDistribution(stats: stats),
                      const SizedBox(height: AppSpacing.lg),
                      _TaskDistributionList(
                        distributions: stats.taskDistributions,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _RotationSection(
                        suggestionsAsync: suggestionsAsync,
                        dismissedTaskIds: _dismissedSuggestionTaskIds,
                        applyingTaskIds: _applyingSuggestionTaskIds,
                        onApply: _applySuggestion,
                        onKeepCurrent: _keepCurrent,
                        onRetry: () => ref.invalidate(
                          taskRotationSuggestionsProvider(widget.householdId),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Period selector — three equal-width cells in one tonal track, built
// locally rather than with `SegmentedButton`. Real Android testing (Gate B)
// found the M3 segmented control wrapped "30 days" onto two lines and made
// the selected segment read as heavy, because each segment's own minimum
// width (from the shared `SegmentedButtonTheme`) doesn't adapt to the
// available width the way three `Expanded` cells do by construction. This is
// a local, one-screen replacement — the shared `SegmentedButtonTheme` (still
// used by the Task Form's Repeat control) is untouched.
// ---------------------------------------------------------------------------

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.selected, required this.onChanged});

  final HouseholdStatsPeriod selected;
  final ValueChanged<HouseholdStatsPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainerLow,
        shape: const StadiumBorder(),
      ),
      child: Row(
        children: [
          for (final period in HouseholdStatsPeriod.values) ...[
            if (period != HouseholdStatsPeriod.values.first)
              const SizedBox(width: 4),
            Expanded(
              child: _PeriodCell(
                label: period.label,
                selected: period == selected,
                onTap: () => onChanged(period),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeriodCell extends StatelessWidget {
  const _PeriodCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final targetTextColor = selected
        ? colorScheme.onPrimary
        : colorScheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        color: selected ? colorScheme.primary : Colors.transparent,
        shape: const StadiumBorder(),
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.sm,
                horizontal: AppSpacing.xs,
              ),
              child: Center(
                child: Semantics(
                  button: true,
                  selected: selected,
                  label: label,
                  excludeSemantics: true,
                  child: TweenAnimationBuilder<Color?>(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    tween: ColorTween(end: targetTextColor),
                    builder: (context, color, _) => Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero — the one dominant real metric this screen shows. The factual balance
// caption is real domain output (`buildFairnessInsight`), not a score —
// shown as quiet supporting text under the number rather than a separate
// decorative card.
// ---------------------------------------------------------------------------

class _StatisticsHero extends StatelessWidget {
  const _StatisticsHero({required this.stats});

  final HouseholdStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AppSoftCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Semantics(
        label:
            '${stats.totalCompletedTasks} completed tasks. ${stats.fairnessInsight}',
        excludeSemantics: true,
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Completed tasks',
              style: theme.textTheme.eyebrow?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              stats.totalCompletedTasks.toString(),
              style: theme.textTheme.heroNumber?.copyWith(fontSize: 44),
            ),
            const SizedBox(height: 4),
            Text(
              stats.fairnessInsight,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Member distribution — horizontal bars. No pie/donut, no ranking medal, no
// winner/loser wording. The text itself ("N tasks - X%") already carries the
// full meaning, so the bar is a visual reinforcement, never the only signal.
// ---------------------------------------------------------------------------

class _MemberDistribution extends StatelessWidget {
  const _MemberDistribution({required this.stats});

  final HouseholdStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSoftCard(
      padding: const EdgeInsets.all(AppSpacing.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Member distribution',
            style: theme.textTheme.eyebrow?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (stats.memberStats.isEmpty)
            const Text('No completed tasks in this period.')
          else
            ...stats.memberStats.map(
              (member) => _MemberStatsRow(member: member),
            ),
        ],
      ),
    );
  }
}

class _MemberStatsRow extends StatelessWidget {
  const _MemberStatsRow({required this.member});

  final MemberTaskStats member;

  @override
  Widget build(BuildContext context) {
    final label =
        '${member.completedTaskCount} '
        '${_taskLabel(member.completedTaskCount)} - ${member.sharePercent}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    member.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(label),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: member.sharePercent / 100,
                minHeight: 6,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerLow,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _taskLabel(int count) => count == 1 ? 'task' : 'tasks';

// ---------------------------------------------------------------------------
// Recurring task patterns — lightweight rows, no card per task.
// ---------------------------------------------------------------------------

class _TaskDistributionList extends StatelessWidget {
  const _TaskDistributionList({required this.distributions});

  final List<TaskDistribution> distributions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSoftCard(
      padding: const EdgeInsets.all(AppSpacing.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recurring tasks',
            style: theme.textTheme.eyebrow?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (distributions.isEmpty)
            const Text('No recurring task distribution yet.')
          else
            ...distributions.map(
              (distribution) => Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        distribution.taskTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        distribution.memberCounts
                            .map((m) => '${m.displayName} ${m.count}')
                            .join(' - '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rotation section — correctness first: an error fetching suggestions must
// never read as "everything is balanced." Loading renders nothing (a brief,
// non-critical, supplementary section), an error shows a compact recoverable
// message, and "no suggestions" — genuinely empty data — renders nothing at
// all, matching the existing quiet no-pattern behaviour.
// ---------------------------------------------------------------------------

class _RotationSection extends StatelessWidget {
  const _RotationSection({
    required this.suggestionsAsync,
    required this.dismissedTaskIds,
    required this.applyingTaskIds,
    required this.onApply,
    required this.onKeepCurrent,
    required this.onRetry,
  });

  final AsyncValue<List<TaskRotationSuggestion>> suggestionsAsync;
  final Set<String> dismissedTaskIds;
  final Set<String> applyingTaskIds;
  final ValueChanged<TaskRotationSuggestion> onApply;
  final ValueChanged<TaskRotationSuggestion> onKeepCurrent;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // `hasError` is checked before `isLoading`: `AsyncValue.isLoading` can be
    // true even when `hasError` is also true (Riverpod's combined
    // loading/refreshing flag), so checking loading first would silently
    // swallow a real error as "still loading" and never show it.
    if (suggestionsAsync.hasError) {
      final colorScheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Could not load rotation suggestions.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (!suggestionsAsync.hasValue) return const SizedBox.shrink();

    final suggestions = suggestionsAsync.requireValue
        .where((s) => !dismissedTaskIds.contains(s.taskId))
        .toList();
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Rotation suggestions',
          style: Theme.of(context).textTheme.eyebrow?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final suggestion in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _RotationSuggestionBlock(
              suggestion: suggestion,
              isApplying: applyingTaskIds.contains(suggestion.taskId),
              onApply: () => onApply(suggestion),
              onKeepCurrent: () => onKeepCurrent(suggestion),
            ),
          ),
      ],
    );
  }
}

class _RotationSuggestionBlock extends StatelessWidget {
  const _RotationSuggestionBlock({
    required this.suggestion,
    required this.isApplying,
    required this.onApply,
    required this.onKeepCurrent,
  });

  final TaskRotationSuggestion suggestion;
  final bool isApplying;
  final VoidCallback onApply;
  final VoidCallback onKeepCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // Stays tonal/pastel, not the white `AppSoftCard` fill — a restrained
    // shadow is layered on via the outer `DecoratedBox` without turning
    // this into another white metric card, so it keeps reading as a
    // secondary, advisory block rather than another analytics hero
    // (`docs/new_design`).
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        shadows: AppShadows.card,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.base),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.sync_alt_rounded,
                    size: 17,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pattern noticed',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        suggestion.taskTitle,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        suggestion.reasonText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Suggested next assignment',
                        style: theme.textTheme.eyebrow?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        suggestion.suggestionText,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // "Adjust manually" (the third action in the original design
            // reference) is deliberately not implemented: opening the Task
            // Form here for `suggestion.taskId` needs a single-task lookup
            // that doesn't exist on `TaskRepository` (only `watchTasks` for
            // a whole household), and Statistics has no existing
            // dependency on the Tasks feature's providers or its private
            // form-opening helper. Adding either is new cross-feature/data
            // architecture, not a UI cleanup — deferred per the Phase H
            // VERIFY-BEFORE-FIX rule rather than faked.
            //
            // Wraps rather than forcing both actions into one Row, so a
            // large text scale never cramps or clips either label.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                TextButton(
                  onPressed: isApplying ? null : onKeepCurrent,
                  child: const Text('Keep current'),
                ),
                FilledButton(
                  onPressed: isApplying ? null : onApply,
                  child: isApplying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Apply suggestion'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
