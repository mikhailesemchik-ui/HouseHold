import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

/// The three states `_AssigneeField` renders. A pure, directly-testable
/// mapping from the provider's `AsyncValue` — this Riverpod version does not
/// reliably surface an overridden provider's error state inside the
/// widget-test harness in every configuration, so the actual state-choosing
/// logic lives here where it can be verified with hand-built `AsyncValue`s
/// regardless of that limitation.
enum AssigneeFieldState { loading, error, ready }

AssigneeFieldState resolveAssigneeFieldState(
  AsyncValue<List<TaskMember>> membersAsync,
) {
  if (membersAsync.isLoading) return AssigneeFieldState.loading;
  if (membersAsync.hasError) return AssigneeFieldState.error;
  return AssigneeFieldState.ready;
}

/// Full-screen task create/edit form.
///
/// Was an `AlertDialog` (`TaskFormDialog`). On a real device, with the
/// keyboard open the dialog's fixed height truncated Description, partially
/// hid Assign to, and squeezed the action buttons — a dialog cannot host 5
/// fields plus two native pickers. A full page scrolls and resizes for the
/// keyboard the normal Flutter way, which is what actually fixes it.
class TaskFormScreen extends ConsumerStatefulWidget {
  const TaskFormScreen({
    super.key,
    required this.householdId,
    this.existingTask,
  });

  final String householdId;
  final Task? existingTask;

  @override
  ConsumerState<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends ConsumerState<TaskFormScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  String? _selectedAssigneeId;
  DateTime? _dueAt;
  RecurrenceType _recurrenceType = RecurrenceType.none;
  String? _titleError;
  String? _dueRecurrenceError;
  bool _isSubmitting = false;
  bool _isDirty = false;

  bool get _isEdit => widget.existingTask != null;

  @override
  void initState() {
    super.initState();
    final task = widget.existingTask;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descriptionController = TextEditingController(
      text: task?.description ?? '',
    );
    _selectedAssigneeId = task?.assignedTo;
    _dueAt = task?.dueAt;
    _recurrenceType = task?.recurrenceType ?? RecurrenceType.none;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onTitleChanged(String _) {
    setState(() {
      _isDirty = true;
      if (_titleError != null) _titleError = null;
    });
  }

  void _onDescriptionChanged(String _) {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  void _onAssigneeChanged(String? value) {
    setState(() {
      _selectedAssigneeId = value;
      _isDirty = true;
    });
  }

  void _onRecurrenceChanged(RecurrenceType value) {
    setState(() {
      _recurrenceType = value;
      _isDirty = true;
    });
  }

  Future<void> _pickDueDateTime() async {
    final now = DateTime.now();
    final initialDate = _dueAt?.toLocal() ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (date == null || !mounted) return;
    final initialTime = _dueAt != null
        ? TimeOfDay.fromDateTime(_dueAt!.toLocal())
        : TimeOfDay.now();
    final time = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (time == null || !mounted) return;
    setState(() {
      _dueAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ).toUtc();
      _dueRecurrenceError = null;
      _isDirty = true;
    });
  }

  void _clearDueDate() {
    setState(() {
      _dueAt = null;
      _recurrenceType = RecurrenceType.none;
      _dueRecurrenceError = null;
      _isDirty = true;
    });
  }

  Future<void> _submit() async {
    final title = _titleController.text;
    final titleError = TaskRepository.validateTitle(title);
    final dueRecurrenceError = TaskRepository.validateDueRecurrence(
      _recurrenceType,
      _dueAt,
    );
    if (titleError != null || dueRecurrenceError != null) {
      setState(() {
        _titleError = titleError;
        _dueRecurrenceError = dueRecurrenceError;
      });
      return;
    }

    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    try {
      final repo = TaskRepository(supabaseClient);
      if (_isEdit) {
        await repo.updateTask(
          taskId: widget.existingTask!.id,
          title: title,
          description: _descriptionController.text,
          assignedTo: _selectedAssigneeId,
          dueAt: _dueAt,
          recurrenceType: _recurrenceType,
        );
      } else {
        await repo.createTask(
          householdId: widget.householdId,
          title: title,
          description: _descriptionController.text,
          assignedTo: _selectedAssigneeId,
          dueAt: _dueAt,
          recurrenceType: _recurrenceType,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // Form content (title, description, assignee, schedule) is left
      // exactly as entered so the user can retry without redoing work. A
      // network/repository failure is a form-level, recoverable message —
      // never blamed on the Title field, which passed validation.
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save task. Please try again.'),
          ),
        );
      }
    }
  }

  Future<void> _handlePopInvoked(bool didPop, Object? result) async {
    if (didPop) return;
    final discard = await confirmDestructive(
      context,
      title: _isEdit ? 'Discard changes?' : 'Discard task?',
      message: 'Your entered details will be lost.',
      confirmLabel: 'Discard',
    );
    if (!mounted) return;
    if (!discard) return;
    Navigator.of(context).pop();
  }

  static String _formatDueAt(DateTime utc) {
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

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(taskMembersProvider(widget.householdId));
    final colorScheme = Theme.of(context).colorScheme;

    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — it's the first item of the same `ListView` the form
    // fields live in, unpadded (matching the removed AppBar's own
    // edge-to-edge geometry) so it scrolls away with the rest of the form
    // and returns naturally at the top. `AppBar` itself picks `CloseButton`
    // vs `BackButton` from `ModalRoute.fullscreenDialog` (see its
    // `useCloseButton` logic) — replicated here so the leading icon stays
    // exactly what it was for both the `fullscreenDialog` production route
    // and a plain-push host (e.g. this screen's own widget tests).
    final useCloseButton = ModalRoute.of(context)?.fullscreenDialog ?? false;
    final header = AppScreenHeader(
      leading: Center(
        child: useCloseButton ? const AppCloseButton() : const AppBackButton(),
      ),
      title: _isEdit ? 'Edit task' : 'New task',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          child: Center(
            child: _isSubmitting
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: _submit,
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.primary,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: Text(_isEdit ? 'Save' : 'Create'),
                  ),
          ),
        ),
      ],
    );

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: _handlePopInvoked,
      child: Scaffold(
        // Pushed on the root navigator, outside the shell's `AppBackground`
        // — see `appFlatBackgroundFallback`'s doc comment.
        backgroundColor: appFlatBackgroundFallback,
        // A plain scrollable ListView inside a real Scaffold resizes for the
        // keyboard on its own — no manual viewInsets math, no fixed height to
        // overflow. This is the actual fix for the keyboard problems observed
        // on device with the old AlertDialog.
        body: SafeArea(
          child: ListView(
            // The header must stay unpadded — the form fields' horizontal/
            // bottom insets live on the inner `Padding` below instead of
            // on this outer list, which opts out of auto-consuming
            // MediaQuery itself so the inner Padding's own bottom value
            // isn't double-counted.
            padding: EdgeInsets.zero,
            children: [
              header,
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.base,
                  AppSpacing.base,
                  AppSpacing.base,
                  AppSpacing.xl,
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _titleController,
                      // Autofocus only for a brand-new task — jumping straight to the
                      // keyboard when editing would cover the values being reviewed.
                      autofocus: !_isEdit,
                      decoration: InputDecoration(
                        labelText: 'Title',
                        errorText: _titleError,
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.next,
                      onChanged: _onTitleChanged,
                    ),
                    const SizedBox(height: AppSpacing.base),
                    _AssigneeField(
                      selectedId: _selectedAssigneeId,
                      membersAsync: membersAsync,
                      onChanged: _onAssigneeChanged,
                      onRetry: () => ref.invalidate(
                        taskMembersProvider(widget.householdId),
                      ),
                    ),
                    const AppSectionHeader(label: 'Schedule'),
                    _DueDateRow(
                      dueAt: _dueAt,
                      formatDueAt: _formatDueAt,
                      onPick: _pickDueDateTime,
                      onClear: _clearDueDate,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _RecurrenceField(
                      value: _recurrenceType,
                      enabled: _dueAt != null,
                      errorText: _dueRecurrenceError,
                      onChanged: _onRecurrenceChanged,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'Add extra details (optional)',
                        alignLabelWithHint: true,
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      maxLines: 4,
                      minLines: 1,
                      onChanged: _onDescriptionChanged,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Assignee — small membership counts make a plain dropdown the simplest
// correct picker; no need for a modal sheet or custom people-picker. Members
// loading/error is shown honestly rather than silently collapsing to
// "Unassigned", which would misrepresent an unresolved or failed fetch as an
// actual, deliberate choice.
// ---------------------------------------------------------------------------

class _AssigneeField extends StatelessWidget {
  const _AssigneeField({
    required this.selectedId,
    required this.membersAsync,
    required this.onChanged,
    required this.onRetry,
  });

  final String? selectedId;
  final AsyncValue<List<TaskMember>> membersAsync;
  final ValueChanged<String?> onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (resolveAssigneeFieldState(membersAsync)) {
      case AssigneeFieldState.loading:
        return InputDecorator(
          decoration: const InputDecoration(labelText: 'Assign to'),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Loading members…',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      case AssigneeFieldState.error:
        return InputDecorator(
          decoration: const InputDecoration(labelText: 'Assign to'),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Could not load members.',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      case AssigneeFieldState.ready:
        final members = membersAsync.requireValue;
        final value = members.any((m) => m.userId == selectedId)
            ? selectedId
            : null;
        return InputDecorator(
          decoration: const InputDecoration(labelText: 'Assign to'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: value,
              isExpanded: true,
              items: [
                const DropdownMenuItem(value: null, child: Text('Unassigned')),
                ...members.map(
                  (m) => DropdownMenuItem(
                    value: m.userId,
                    child: Text(m.displayName, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: onChanged,
            ),
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Due date — single combined date+time flow (matches the domain model: one
// `dueAt` instant, no separate all-day/date-only concept).
// ---------------------------------------------------------------------------

class _DueDateRow extends StatelessWidget {
  const _DueDateRow({
    required this.dueAt,
    required this.formatDueAt,
    required this.onPick,
    required this.onClear,
  });

  final DateTime? dueAt;
  final String Function(DateTime) formatDueAt;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDueDate = dueAt != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            Icons.event_rounded,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              hasDueDate ? formatDueAt(dueAt!) : 'No due date',
              style: hasDueDate
                  ? theme.textTheme.bodyLarge
                  : theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onPick,
            child: Text(hasDueDate ? 'Change' : 'Set due date'),
          ),
          if (hasDueDate)
            IconButton(
              icon: const Icon(Icons.clear_rounded, size: 18),
              tooltip: 'Clear due date',
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recurrence — exactly 3 options, so a SegmentedButton shows every choice at
// a glance (matches the period selector already used on Statistics) rather
// than hiding them behind a dropdown menu. Disabled without a due date,
// matching `TaskRepository.validateDueRecurrence`.
// ---------------------------------------------------------------------------

class _RecurrenceField extends StatelessWidget {
  const _RecurrenceField({
    required this.value,
    required this.enabled,
    required this.errorText,
    required this.onChanged,
  });

  final RecurrenceType value;
  final bool enabled;
  final String? errorText;
  final ValueChanged<RecurrenceType> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      // The theme's InputDecorationTheme defines real enabled/focused
      // borders, which win over a lone `border: InputBorder.none` — this
      // decorator wraps a SegmentedButton and must stay outline-free.
      decoration: kBorderlessInputDecoration.copyWith(
        labelText: 'Repeat',
        errorText: errorText,
        helperText: enabled ? null : 'Set a due date to enable repeat',
      ),
      child: SegmentedButton<RecurrenceType>(
        segments: const [
          ButtonSegment(value: RecurrenceType.none, label: Text('None')),
          ButtonSegment(value: RecurrenceType.daily, label: Text('Daily')),
          ButtonSegment(value: RecurrenceType.weekly, label: Text('Weekly')),
        ],
        selected: {value},
        onSelectionChanged: enabled
            ? (selection) => onChanged(selection.first)
            : null,
      ),
    );
  }
}
