import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_event.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';

class TaskRepository {
  const TaskRepository(this._client);

  final SupabaseClient _client;

  /// Streams all tasks for [householdId] via Supabase Realtime.
  /// Incomplete tasks are sorted before completed; both groups sorted by
  /// creation time. Sort is client-side because the stream API does not
  /// support multi-column ordering across the null boundary.
  Stream<List<Task>> watchTasks(String householdId) {
    return _client
        .from('tasks')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('created_at')
        .map((rows) {
          final tasks = rows.map(Task.fromMap).toList();
          tasks.sort((a, b) {
            if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
            return a.createdAt.compareTo(b.createdAt);
          });
          return tasks;
        });
  }

  /// Streams all occurrences for [householdId] via Supabase Realtime.
  /// Sort order: overdue incomplete → upcoming incomplete → completed.
  Stream<List<TaskOccurrence>> watchUpcomingOccurrences(String householdId) {
    return _client
        .from('task_occurrences')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('scheduled_at')
        .map((rows) {
          final occurrences = rows.map(TaskOccurrence.fromMap).toList();
          occurrences.sort((a, b) {
            if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
            return a.scheduledAt.compareTo(b.scheduledAt);
          });
          return occurrences;
        });
  }

  Future<void> createTask({
    required String householdId,
    required String title,
    String? description,
    String? assignedTo,
    DateTime? dueAt,
    RecurrenceType recurrenceType = RecurrenceType.none,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');
    await _client.from('tasks').insert({
      'household_id': householdId,
      'title': title.trim(),
      'description': description != null && description.trim().isNotEmpty
          ? description.trim()
          : null,
      'assigned_to': assignedTo,
      'created_by': userId,
      'due_at': dueAt?.toUtc().toIso8601String(),
      'recurrence_type': recurrenceType.value,
    });
  }

  Future<void> updateTask({
    required String taskId,
    required String title,
    String? description,
    String? assignedTo,
    DateTime? dueAt,
    RecurrenceType recurrenceType = RecurrenceType.none,
  }) async {
    await _client
        .from('tasks')
        .update({
          'title': title.trim(),
          'description': description != null && description.trim().isNotEmpty
              ? description.trim()
              : null,
          'assigned_to': assignedTo,
          'due_at': dueAt?.toUtc().toIso8601String(),
          'recurrence_type': recurrenceType.value,
        })
        .eq('id', taskId);
  }

  Future<void> completeTask(String taskId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');
    await _client
        .from('tasks')
        .update({
          'completed_at': DateTime.now().toUtc().toIso8601String(),
          'completed_by': userId,
        })
        .eq('id', taskId);
  }

  Future<void> reopenTask(String taskId) async {
    await _client
        .from('tasks')
        .update({'completed_at': null, 'completed_by': null})
        .eq('id', taskId);
  }

  Future<void> deleteTask(String taskId) async {
    await _client.from('tasks').delete().eq('id', taskId);
  }

  /// Completes an occurrence via the server-side RPC, which enforces
  /// completed_by = auth.uid() and records a task_event.
  Future<void> completeOccurrence(String occurrenceId) async {
    await _client.rpc(
      'complete_occurrence',
      params: {'p_occurrence_id': occurrenceId},
    );
  }

  /// Reopens a completed occurrence via the server-side RPC.
  Future<void> reopenOccurrence(String occurrenceId) async {
    await _client.rpc(
      'reopen_occurrence',
      params: {'p_occurrence_id': occurrenceId},
    );
  }

  /// Fetches active members of [householdId] for the assignment dropdown.
  Future<List<TaskMember>> fetchMembers(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('user_id, profiles(display_name, public_id)')
        .eq('household_id', householdId)
        .eq('status', 'active');
    return rows.map(TaskMember.fromMap).toList();
  }

  /// Returns the 10 most recent task events for a household, newest first.
  Future<List<TaskEvent>> fetchRecentActivity(String householdId) async {
    final rows = await _client
        .from('task_events')
        .select('*, actor_profile:profiles!actor_user_id(display_name)')
        .eq('household_id', householdId)
        .order('occurred_at', ascending: false)
        .limit(10);
    return rows.map(TaskEvent.fromMap).toList();
  }

  /// Fetches incomplete occurrences assigned to the current user across all
  /// active households, ordered by scheduled time.
  /// Reserved for a future cross-household "My Tasks" UI.
  Future<List<TaskOccurrence>> fetchAssignedOccurrences() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');
    final rows = await _client
        .from('task_occurrences')
        .select()
        .eq('assigned_to', userId)
        .isFilter('completed_at', null)
        .order('scheduled_at');
    return rows.map(TaskOccurrence.fromMap).toList();
  }

  static String? validateTitle(String title) {
    if (title.trim().isEmpty) return 'Task title cannot be blank';
    return null;
  }

  /// Returns an error string when recurrence requires a due date that is absent.
  static String? validateDueRecurrence(
    RecurrenceType recurrenceType,
    DateTime? dueAt,
  ) {
    if (recurrenceType != RecurrenceType.none && dueAt == null) {
      return 'Recurring task requires a due date';
    }
    return null;
  }
}
