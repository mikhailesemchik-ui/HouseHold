import 'package:supabase_flutter/supabase_flutter.dart';

class TodayRepository {
  const TodayRepository(this._client);

  final SupabaseClient _client;

  String? get _userId => _client.auth.currentUser?.id;

  /// Streams all task_occurrences assigned to the current user across all
  /// households. Filtering for incomplete entries is done in the provider.
  Stream<List<Map<String, dynamic>>> watchAssignedOccurrenceRows() {
    final userId = _userId;
    if (userId == null) return const Stream.empty();
    return _client
        .from('task_occurrences')
        .stream(primaryKey: ['id'])
        .eq('assigned_to', userId);
  }

  /// Streams all tasks assigned to the current user across all households.
  /// Used for title/recurrenceType lookup (for occurrences) and anytime tasks.
  Stream<List<Map<String, dynamic>>> watchAssignedTaskRows() {
    final userId = _userId;
    if (userId == null) return const Stream.empty();
    return _client
        .from('tasks')
        .stream(primaryKey: ['id'])
        .eq('assigned_to', userId);
  }

  /// One-shot equivalent of [watchAssignedOccurrenceRows], for callers that
  /// cannot hold a realtime subscription open (e.g. a background isolate).
  Future<List<Map<String, dynamic>>> fetchAssignedOccurrenceRows() async {
    final userId = _userId;
    if (userId == null) return const [];
    return _client.from('task_occurrences').select().eq('assigned_to', userId);
  }

  /// One-shot equivalent of [watchAssignedTaskRows].
  Future<List<Map<String, dynamic>>> fetchAssignedTaskRows() async {
    final userId = _userId;
    if (userId == null) return const [];
    return _client.from('tasks').select().eq('assigned_to', userId);
  }

  /// Extends the rolling occurrence horizon for the caller's recurring tasks.
  /// Failure is suppressed at the call site so existing data remains visible.
  Future<void> refreshRecurringOccurrences() async {
    await _client.rpc('refresh_my_recurring_occurrences');
  }
}
