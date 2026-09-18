import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';

/// Streams tasks for a household via Supabase Realtime.
/// autoDispose cancels the stream subscription when the screen is left.
final tasksStreamProvider = StreamProvider.autoDispose
    .family<List<Task>, String>(
      (ref, householdId) =>
          TaskRepository(supabaseClient).watchTasks(householdId),
    );

/// Streams task occurrences for a household via Supabase Realtime.
/// Sorted: overdue incomplete → upcoming incomplete → completed.
final occurrencesStreamProvider = StreamProvider.autoDispose
    .family<List<TaskOccurrence>, String>(
      (ref, householdId) =>
          TaskRepository(supabaseClient).watchUpcomingOccurrences(householdId),
    );

/// Fetches active members of a household for the task assignment dropdown.
final taskMembersProvider = FutureProvider.family<List<TaskMember>, String>((
  ref,
  householdId,
) {
  return TaskRepository(supabaseClient).fetchMembers(householdId);
});
