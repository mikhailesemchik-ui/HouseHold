import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_completion_checkbox.dart';
import 'package:household_os/core/widgets/app_completion_title.dart';
import 'package:household_os/core/widgets/app_pressable_scale.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';
import 'package:household_os/features/tasks/presentation/task_form_screen.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

/// Gate for the two independent task streams. Occurrence data is
/// supplementary schedule metadata, not the tasks themselves: a tasks-stream
/// failure genuinely blocks the screen (there is nothing to show), but an
/// occurrences failure must only degrade the schedule-dependent presentation
/// — it must never hide tasks that already loaded successfully.
enum TasksLoadState { loading, tasksError, ready }

TasksLoadState resolveTasksLoadState(
  AsyncValue<List<Task>> tasksAsync,
  AsyncValue<List<TaskOccurrence>> occurrencesAsync,
) {
  if (!tasksAsync.hasValue && tasksAsync.isLoading) {
    return TasksLoadState.loading;
  }
  if (!tasksAsync.hasValue && tasksAsync.hasError) {
    return TasksLoadState.tasksError;
  }
  return TasksLoadState.ready;
}

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key, required this.householdId});

  final String householdId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(body: _TasksBody(householdId: householdId));
  }
}

class _TasksBody extends ConsumerWidget {
  const _TasksBody({required this.householdId});

  final String householdId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(tasksStreamProvider(householdId));
    final occurrencesAsync = ref.watch(occurrencesStreamProvider(householdId));
    final members = switch (ref.watch(taskMembersProvider(householdId))) {
      AsyncData(:final value) => value,
      _ => <TaskMember>[],
    };

    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — every branch below places it as the first item of its
    // own scrollable, so it scrolls away with the page and returns
    // naturally at the top.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Tasks',
    );

    switch (resolveTasksLoadState(tasksAsync, occurrencesAsync)) {
      case TasksLoadState.loading:
        return Stack(
          children: [
            SafeArea(
              top: false,
              bottom: false,
              child: ListView(
                padding: EdgeInsets.only(
                  bottom: context.shellBottomInset + kFabClearance,
                ),
                children: const [header, _TasksLoadingBody()],
              ),
            ),
            Positioned(
              right: AppSpacing.base,
              bottom: context.shellBottomInset + AppSpacing.base,
              child: AppPressableScale(
                child: FloatingActionButton.extended(
                  onPressed: () =>
                      _openTaskForm(context, householdId: householdId),
                  label: const Text('Add task'),
                  icon: const Icon(Icons.add_rounded),
                ),
              ),
            ),
          ],
        );
      case TasksLoadState.tasksError:
        return SafeArea(
          top: false,
          bottom: false,
          child: ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load tasks. Please try again.',
                onRetry: () => ref.invalidate(tasksStreamProvider(householdId)),
              ),
            ],
          ),
        );
      case TasksLoadState.ready:
        break;
    }

    final tasks = tasksAsync.requireValue;
    final tasksById = {for (final t in tasks) t.id: t};
    final nonDueTasks = tasks.where((t) => t.dueAt == null).toList();

    final occurrencesData = occurrencesAsync.asData?.value;
    final occurrencesFailed = occurrencesAsync.hasError;
    final occurrencesPending = occurrencesData == null && !occurrencesFailed;

    // Only claim "no tasks" once occurrence data has actually resolved —
    // otherwise a legitimate due-date task could flash as absent while its
    // occurrence is still loading.
    final isEmpty = nonDueTasks.isEmpty && (occurrencesData?.isEmpty ?? false);

    if (isEmpty) {
      return SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          children: [
            header,
            AppEmptyState(
              icon: Icons.checklist_rounded,
              title: 'No tasks yet',
              subtitle:
                  'Add a task to start organizing what this household needs to do.',
              actionLabel: 'Add task',
              onAction: () => _openTaskForm(context, householdId: householdId),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        SafeArea(
          top: false,
          bottom: false,
          child: ListView(
            // Explicit padding opts out of automatic MediaQuery
            // consumption, so the nav clearance is re-applied here,
            // plus room for the FAB.
            padding: EdgeInsets.only(
              bottom: context.shellBottomInset + kFabClearance,
            ),
            children: [
              header,
              ...nonDueTasks.map(
                (t) => _TaskListRow(
                  title: t.title,
                  isCompleted: t.isCompleted,
                  assigneeLabel: _assigneeLabel(members, t.assignedTo),
                  scheduleText: null,
                  isOverdue: false,
                  recurrenceType: t.recurrenceType,
                  onToggle: () => _toggleTask(context, t),
                  onEdit: () => _openTaskForm(
                    context,
                    householdId: householdId,
                    existingTask: t,
                  ),
                  onDelete: () => _deleteTask(context, t),
                ),
              ),
              if (occurrencesFailed)
                _InlineSectionError(
                  message: 'Could not load scheduled tasks.',
                  onRetry: () =>
                      ref.invalidate(occurrencesStreamProvider(householdId)),
                )
              else if (occurrencesPending)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.base),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ...(occurrencesData ?? const <TaskOccurrence>[]).map((o) {
                  final task = tasksById[o.taskId];
                  if (task == null) return const SizedBox.shrink();
                  return _TaskListRow(
                    title: task.title,
                    isCompleted: o.isCompleted,
                    assigneeLabel: _assigneeLabel(members, o.assignedTo),
                    scheduleText: _formatScheduled(o.scheduledAt),
                    isOverdue: o.isOverdue,
                    recurrenceType: task.recurrenceType,
                    onToggle: () => _toggleOccurrence(context, o),
                    onEdit: () => _openTaskForm(
                      context,
                      householdId: householdId,
                      existingTask: task,
                    ),
                    onDelete: () => _deleteTask(context, task),
                  );
                }),
            ],
          ),
        ),
        // FAB: only over a ready, populated list — not while loading/erroring
        // (nothing to float a creation control over) and not over the empty
        // state, which already offers its own "Add task" action.
        Positioned(
          right: AppSpacing.base,
          bottom: context.shellBottomInset + AppSpacing.base,
          child: AppPressableScale(
            child: FloatingActionButton.extended(
              onPressed: () => _openTaskForm(context, householdId: householdId),
              label: const Text('Add task'),
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
      ],
    );
  }
}

class _TasksLoadingBody extends StatelessWidget {
  const _TasksLoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xl,
      ),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

String _assigneeLabel(List<TaskMember> members, String? assignedTo) {
  if (assignedTo == null) return 'Unassigned';
  return members
          .where((m) => m.userId == assignedTo)
          .firstOrNull
          ?.displayName ??
      'Unassigned';
}

String _formatScheduled(DateTime utc) {
  final dt = utc.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${months[dt.month - 1]} ${dt.day} · $h:$m';
}

void _openTaskForm(
  BuildContext context, {
  required String householdId,
  Task? existingTask,
}) {
  // Pushed on the root navigator so the full-screen form sits above the
  // shell entirely (glass nav bar included), not just within this branch's
  // own stack — the "New Task" surface. `tasks/shopping/...` sub-routes stay
  // GoRouter-nested since they're regular in-shell destinations; this form
  // is a modal task, not a destination.
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          TaskFormScreen(householdId: householdId, existingTask: existingTask),
    ),
  );
}

Future<void> _toggleTask(BuildContext context, Task task) async {
  try {
    final repo = TaskRepository(supabaseClient);
    if (task.isCompleted) {
      await repo.reopenTask(task.id);
    } else {
      await repo.completeTask(task.id);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to update task.')));
    }
  }
}

Future<void> _toggleOccurrence(
  BuildContext context,
  TaskOccurrence occurrence,
) async {
  try {
    final repo = TaskRepository(supabaseClient);
    if (occurrence.isCompleted) {
      await repo.reopenOccurrence(occurrence.id);
    } else {
      await repo.completeOccurrence(occurrence.id);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to update task.')));
    }
  }
}

/// Deletes the parent task. There is no per-occurrence delete — an
/// occurrence row shown on this screen always represents (and edits/deletes)
/// its underlying task, including all of that task's future occurrences.
/// This is frozen domain behaviour; only the confirmation wording here makes
/// it explicit rather than ambiguous.
Future<void> _deleteTask(BuildContext context, Task task) async {
  final isRecurring = task.recurrenceType != RecurrenceType.none;
  final confirmed = await confirmDestructive(
    context,
    title: 'Delete "${task.title}"?',
    message: isRecurring
        ? 'This deletes the task and all its future occurrences. This '
              'cannot be undone.'
        : 'This cannot be undone.',
    confirmLabel: 'Delete task',
  );
  if (!confirmed || !context.mounted) return;
  try {
    await TaskRepository(supabaseClient).deleteTask(task.id);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete task.')));
    }
  }
}

// ---------------------------------------------------------------------------
// A compact, non-distorting error treatment for the occurrence-derived
// section: one line + an inline Retry action. A full `AppErrorState` (icon +
// xl padding) is sized for a whole-screen failure, not a section embedded
// among already-successfully-loaded task rows.
// ---------------------------------------------------------------------------

class _InlineSectionError extends StatelessWidget {
  const _InlineSectionError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unified task row — replaces the separate _TaskTile/_OccurrenceTile, which
// were ~90% identical (including their own copies of the delete dialog).
// Content-layer surface: no glass, no feature-colored background.
// ---------------------------------------------------------------------------

class _TaskListRow extends StatelessWidget {
  const _TaskListRow({
    required this.title,
    required this.isCompleted,
    required this.assigneeLabel,
    required this.scheduleText,
    required this.isOverdue,
    required this.recurrenceType,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final bool isCompleted;
  final String assigneeLabel;
  final String? scheduleText;
  final bool isOverdue;
  final RecurrenceType recurrenceType;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Metadata text/icon colour, not a border — `outline` is the app's
    // pinned hairline colour and is too light to read as text.
    final scheduleColor = isOverdue
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    final hasRecurrence = recurrenceType != RecurrenceType.none;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        0,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        onTap: onEdit,
        child: Row(
          children: [
            AppCompletionCheckbox(
              checked: isCompleted,
              semanticLabel:
                  'Mark "$title" as ${isCompleted ? 'not done' : 'done'}',
              onChanged: onToggle,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppCompletionTitle(
                    text: title,
                    completed: isCompleted,
                    baseStyle: textTheme.titleSmall,
                    completedColor: colorScheme.onSurfaceVariant,
                    maxLines: 2,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            assigneeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (scheduleText != null) ...[
                          Text(
                            '  ·  ',
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              scheduleText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheduleColor,
                              ),
                            ),
                          ),
                        ],
                        if (hasRecurrence) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Semantics(
                            label:
                                'Repeats ${recurrenceType.label.toLowerCase()}',
                            excludeSemantics: true,
                            container: true,
                            child: Icon(
                              Icons.repeat,
                              size: 13,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Task actions',
              icon: Icon(
                Icons.more_vert_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
              onSelected: (value) {
                if (value == 'edit') onEdit();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete task')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
