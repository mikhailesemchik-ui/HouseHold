import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/domain/household_member_info.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';

class HouseholdDashboardRepository {
  const HouseholdDashboardRepository(this._client);

  final SupabaseClient _client;

  /// Fetches summary counts for the dashboard in a single parallel batch.
  Future<HouseholdSummary> fetchSummary(String householdId) async {
    final results = await Future.wait([
      _countIncompleteTasks(householdId),
      _countIncompleteShopping(householdId),
      _countExpenses(householdId),
      _countActiveMembers(householdId),
    ]);
    return HouseholdSummary(
      incompleteTaskCount: results[0],
      incompleteShoppingCount: results[1],
      expenseCount: results[2],
      activeMemberCount: results[3],
    );
  }

  // A due-date task's completion lives on its task_occurrences row, not on
  // tasks.completed_at (see complete_occurrence/reopen_occurrence) — that
  // column is only ever set for a task with no due date, completed directly.
  // Counting tasks.completed_at alone for every task therefore counts a
  // completed due-date task as still incomplete forever. Mirror the same
  // split the Tasks screen itself renders: anytime tasks by their own
  // completed_at, due-date tasks by their occurrence's completed_at.
  Future<int> _countIncompleteTasks(String householdId) async {
    final results = await Future.wait([
      _client
          .from('tasks')
          .select('id')
          .eq('household_id', householdId)
          .isFilter('due_at', null)
          .isFilter('completed_at', null),
      _client
          .from('task_occurrences')
          .select('id')
          .eq('household_id', householdId)
          .isFilter('completed_at', null),
    ]);
    return results[0].length + results[1].length;
  }

  Future<int> _countIncompleteShopping(String householdId) async {
    final rows = await _client
        .from('shopping_items')
        .select('id')
        .eq('household_id', householdId)
        .isFilter('completed_at', null);
    return rows.length;
  }

  Future<int> _countExpenses(String householdId) async {
    final rows = await _client
        .from('expenses')
        .select('id')
        .eq('household_id', householdId);
    return rows.length;
  }

  Future<int> _countActiveMembers(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('user_id')
        .eq('household_id', householdId)
        .eq('status', 'active');
    return rows.length;
  }

  /// Fetches active members with display name, publicId, and role.
  Future<List<HouseholdMemberInfo>> fetchMembers(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('user_id, role, joined_at, profiles(display_name, public_id)')
        .eq('household_id', householdId)
        .eq('status', 'active')
        .order('joined_at');
    return rows.map(HouseholdMemberInfo.fromMap).toList();
  }

  /// Fetches the [limit] most recent household events, newest first.
  Future<List<HouseholdEvent>> fetchRecentActivity(
    String householdId, {
    int limit = 5,
  }) async {
    final rows = await _client
        .from('household_events')
        .select()
        .eq('household_id', householdId)
        .order('occurred_at', ascending: false)
        .limit(limit);
    return rows.map(HouseholdEvent.fromMap).toList();
  }

  /// Fetches all household events for the full activity screen, newest first.
  Future<List<HouseholdEvent>> fetchActivity(String householdId) async {
    final rows = await _client
        .from('household_events')
        .select()
        .eq('household_id', householdId)
        .order('occurred_at', ascending: false);
    return rows.map(HouseholdEvent.fromMap).toList();
  }

  /// Streams household_events for this household. Used only to detect that
  /// new events arrived (e.g. a remote member joined) so cached member/
  /// summary/activity state can be invalidated — not for rendering directly.
  Stream<List<HouseholdEvent>> watchEvents(String householdId) {
    return _client
        .from('household_events')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('occurred_at')
        .map((rows) => rows.map(HouseholdEvent.fromMap).toList());
  }
}
