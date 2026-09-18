import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_completion_checkbox.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(todayProvider.notifier).reconcileReminders().ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sectionsAsync = ref.watch(todayProvider);

    // The header is ordinary scrollable content (not a pinned `AppBar`), so
    // it lives as the first item of the one list every branch below shares
    // — it scrolls away with the rest of the page and returns naturally at
    // the top, per the Non-Sticky Headers change.
    final List<Widget> bodyChildren = sectionsAsync.when(
      loading: () => const [
        AppSkeletonList(
          sectionCounts: {'Today': 3, 'Upcoming': 2},
          scrollable: false,
        ),
      ],
      error: (_, _) => [
        AppErrorState(
          message: 'Could not load tasks. Please try again.',
          onRetry: () => ref.invalidate(todayProvider),
        ),
      ],
      data: (sections) {
        final allEmpty = sections.values.every((list) => list.isEmpty);
        if (allEmpty) {
          return const [
            AppEmptyState(
              icon: Icons.check_circle_outline,
              title: 'Nothing assigned to you.',
              subtitle: 'Assigned tasks from all your homes will appear here.',
              alignment: Alignment(0, -0.3),
            ),
          ];
        }
        return [
          ..._buildSection(
            context,
            'Overdue',
            sections['overdue']!,
            isWarning: true,
          ),
          ..._buildSection(context, 'Today', sections['today']!),
          ..._buildSection(context, 'Upcoming', sections['upcoming']!),
          ..._buildSection(context, 'Anytime', sections['anytime']!),
        ];
      },
    );

    return Scaffold(
      // SafeArea handles the top status-bar inset that the removed AppBar
      // used to consume; the list's own null `padding` still auto-consumes
      // the shell's bottom nav clearance exactly as before.
      body: SafeArea(
        bottom: false,
        child: ListView(
          children: [
            const AppScreenHeader(title: 'Today', bottom: _DateSubtitle()),
            ...bodyChildren,
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSection(
    BuildContext context,
    String label,
    List<TodayEntry> entries, {
    bool isWarning = false,
  }) {
    if (entries.isEmpty) return const [];
    return [
      AppSectionHeader(label: label, isWarning: isWarning),
      ...entries.map((e) => _TodayEntryTile(entry: e)),
    ];
  }
}

// ---------------------------------------------------------------------------
// Date subtitle under the header title
// ---------------------------------------------------------------------------

class _DateSubtitle extends StatelessWidget {
  const _DateSubtitle();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final label =
        '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.base,
          0,
          AppSpacing.base,
          AppSpacing.sm,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Task row
// ---------------------------------------------------------------------------

class _TodayEntryTile extends StatelessWidget {
  const _TodayEntryTile({required this.entry});

  final TodayEntry entry;

  static String _formatTime(DateTime utc) {
    final local = utc.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _complete(BuildContext context) async {
    try {
      final repo = TaskRepository(supabaseClient);
      if (entry.sourceType == TodayEntrySource.occurrence) {
        await repo.completeOccurrence(entry.occurrenceId!);
      } else {
        await repo.completeTask(entry.taskId);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to complete task.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final timeText = entry.sourceType == TodayEntrySource.anytime
        ? 'Anytime'
        : entry.scheduledAt != null
        ? _formatTime(entry.scheduledAt!)
        : null;
    // Metadata text/icon colour, not a border — `outline` is the app's
    // pinned hairline colour and is too light to read as text.
    final timeColor = entry.isOverdue
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        0,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        onTap: () => context.go('/homes/${entry.householdId}/tasks'),
        child: Row(
          children: [
            // Always unchecked and one-way (tap → complete): this is a "mark
            // done" action, not a toggle. announceState:false keeps screen
            // readers from announcing a checked/unchecked state that doesn't
            // apply here.
            AppCompletionCheckbox(
              checked: false,
              announceState: false,
              semanticLabel: 'Mark "${entry.title}" as done',
              onChanged: () => _complete(context),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    style: textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  _TaskSubtitle(
                    householdName: entry.householdName,
                    timeText: timeText,
                    timeColor: timeColor,
                    recurrenceType: entry.recurrenceType,
                    isOverdue: entry.isOverdue,
                    colorScheme: colorScheme,
                    textTheme: textTheme,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskSubtitle extends StatelessWidget {
  const _TaskSubtitle({
    required this.householdName,
    required this.timeText,
    required this.timeColor,
    required this.recurrenceType,
    required this.isOverdue,
    required this.colorScheme,
    required this.textTheme,
  });

  final String householdName;
  final String? timeText;
  final Color timeColor;
  final RecurrenceType recurrenceType;
  final bool isOverdue;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final metaStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Flexible(
            child: Text(
              householdName,
              style: metaStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (timeText != null) ...[
            Text('  ·  ', style: metaStyle),
            Text(timeText!, style: metaStyle?.copyWith(color: timeColor)),
          ],
          if (recurrenceType != RecurrenceType.none) ...[
            const SizedBox(width: AppSpacing.xs),
            Semantics(
              label: 'Repeats ${recurrenceType.label.toLowerCase()}',
              excludeSemantics: true,
              container: true,
              child: Icon(
                Icons.repeat,
                size: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
