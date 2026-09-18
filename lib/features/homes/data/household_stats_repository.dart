import 'package:household_os/features/homes/domain/household_stats.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class HouseholdStatsRepository {
  const HouseholdStatsRepository(this._client);

  final SupabaseClient _client;

  Future<HouseholdStats> fetchStats({
    required String householdId,
    required HouseholdStatsPeriod period,
    DateTime? now,
  }) async {
    final results = await Future.wait([
      _fetchCompletedTaskEvents(householdId),
      _fetchMemberProfiles(householdId),
    ]);
    final eventRows = results[0];
    final memberRows = results[1];
    final memberLookup = _memberLookup(memberRows);
    final activeMemberCount = memberLookup.values
        .where((m) => m.isActive)
        .length;

    final completions = eventRows.map((row) {
      final actorUserId = row['actor_user_id'] as String?;
      final member = actorUserId == null ? null : memberLookup[actorUserId];
      final actorProfile = row['actor_profile'] as Map<String, dynamic>?;
      final profileName = actorProfile?['display_name'] as String?;
      return TaskCompletionRecord(
        id: row['id'] as String,
        memberKey: actorUserId ?? 'deleted:${row['id']}',
        displayName: resolveStatsMemberDisplayName(
          isActiveMember: member?.isActive,
          profileDisplayName: member?.displayName ?? profileName,
        ),
        taskTitle: row['task_title'] as String? ?? '(unknown task)',
        completedAt: DateTime.parse(row['occurred_at'] as String),
        isActiveMember: member?.isActive ?? false,
      );
    }).toList();

    return HouseholdStats.fromCompletions(
      period: period,
      completions: completions,
      now: now ?? DateTime.now().toUtc(),
      activeMemberCount: activeMemberCount,
    );
  }

  Future<List<TaskRotationSuggestion>> fetchRotationSuggestions({
    required String householdId,
    DateTime? now,
  }) async {
    final currentNow = now ?? DateTime.now().toUtc();
    final results = await Future.wait([
      _fetchRecurringTasks(householdId),
      _fetchCompletedTaskEvents(householdId),
      _fetchMemberProfiles(householdId),
    ]);
    final taskRows = results[0];
    final eventRows = results[1];
    final memberRows = results[2];

    final tasks = taskRows.map((row) {
      return RotationTaskSnapshot(
        id: row['id'] as String,
        title: row['title'] as String,
        assignedTo: row['assigned_to'] as String?,
        recurrenceType: RecurrenceType.parse(row['recurrence_type'] as String),
      );
    }).toList();

    final members = memberRows.map((row) {
      final profile = row['profiles'] as Map<String, dynamic>?;
      return RotationMemberSnapshot(
        userId: row['user_id'] as String,
        displayName: resolveStatsMemberDisplayName(
          isActiveMember: row['status'] == 'active',
          profileDisplayName: profile?['display_name'] as String?,
        ),
        publicId: profile?['public_id'] as String? ?? '',
        isActive: row['status'] == 'active',
      );
    }).toList();

    final completions = eventRows.map((row) {
      return RotationCompletionRecord(
        id: row['id'] as String,
        taskId: row['task_id'] as String? ?? '',
        completedBy: row['actor_user_id'] as String?,
        completedAt: DateTime.parse(row['occurred_at'] as String),
      );
    }).toList();

    final start = currentNow.subtract(rotationAnalysisWindow);
    final overallCounts = <String, int>{};
    for (final completion in completions) {
      final memberId = completion.completedBy;
      if (memberId == null) continue;
      if (completion.completedAt.toUtc().isBefore(start)) continue;
      overallCounts.update(memberId, (count) => count + 1, ifAbsent: () => 1);
    }

    return buildTaskRotationSuggestions(
      tasks: tasks,
      members: members,
      completions: completions,
      overallCompletionCounts: overallCounts,
      now: currentNow,
    );
  }

  Future<void> applyRotationSuggestion(
    TaskRotationSuggestion suggestion,
  ) async {
    final rows = await _client
        .from('tasks')
        .update({'assigned_to': suggestion.suggestedMemberId})
        .eq('id', suggestion.taskId)
        .inFilter('recurrence_type', ['daily', 'weekly'])
        .select('id');
    if (rows.isEmpty) {
      throw StateError('Task is no longer available for rotation.');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchCompletedTaskEvents(
    String householdId,
  ) async {
    final rows = await _client
        .from('task_events')
        .select(
          'id, task_id, actor_user_id, task_title, occurred_at, actor_profile:profiles!actor_user_id(display_name)',
        )
        .eq('household_id', householdId)
        .eq('event_type', 'completed')
        .order('occurred_at', ascending: false);
    return rows.cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> _fetchRecurringTasks(
    String householdId,
  ) async {
    final rows = await _client
        .from('tasks')
        .select('id, title, assigned_to, recurrence_type')
        .eq('household_id', householdId)
        .inFilter('recurrence_type', ['daily', 'weekly']);
    return rows.cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> _fetchMemberProfiles(
    String householdId,
  ) async {
    final rows = await _client
        .from('household_members')
        .select('user_id, status, profiles(display_name, public_id)')
        .eq('household_id', householdId);
    return rows.cast<Map<String, dynamic>>();
  }

  Map<String, _MemberProfileStatus> _memberLookup(
    List<Map<String, dynamic>> rows,
  ) {
    return {
      for (final row in rows)
        row['user_id'] as String: _MemberProfileStatus(
          isActive: row['status'] == 'active',
          displayName:
              (row['profiles'] as Map<String, dynamic>?)?['display_name']
                  as String?,
        ),
    };
  }
}

class _MemberProfileStatus {
  const _MemberProfileStatus({
    required this.isActive,
    required this.displayName,
  });

  final bool isActive;
  final String? displayName;
}
