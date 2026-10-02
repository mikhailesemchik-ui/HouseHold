import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/today/data/today_repository.dart';
import 'package:household_os/features/today/presentation/today_provider.dart'
    show buildTodayEntries, groupTodayEntries;

/// Handles a complete/reopen tap that arrived from the home-screen widget
/// collection, without opening the app. Runs in a background isolate.
///
/// Duplicate taps for the same id while one is already in flight are
/// deduplicated natively (WorkManager `enqueueUniqueWork` with
/// `ExistingWorkPolicy.KEEP` in HouseholdOsWidgetActionReceiver) — this
/// handler never runs concurrently for the same id, so it does not need its
/// own in-flight bookkeeping. An earlier SharedPreferences-backed guard here
/// was removed: under the previous `REPLACE` policy a cancelled in-flight
/// worker could be killed before clearing its own flag, permanently
/// blocking every future tap for that id. Any such stale entry left over
/// from that bug is simply unused now.
class WidgetActionHandler {
  const WidgetActionHandler();

  /// [id] is an occurrenceId when [source] is `occurrence`, a taskId when
  /// [source] is `anytime` — the same identifiers TaskRepository expects.
  /// Mutates through the existing TaskRepository methods, so scheduled
  /// occurrences keep using the server-side RPC path and anytime tasks keep
  /// using direct task completion — no widget-only completion semantics.
  Future<void> handle({
    required String id,
    required String source,
    required String action,
  }) async {
    try {
      if (supabaseClient.auth.currentUser == null) return;

      final repo = TaskRepository(supabaseClient);
      final complete = action == 'complete';
      if (source == 'occurrence') {
        await (complete
            ? repo.completeOccurrence(id)
            : repo.reopenOccurrence(id));
      } else {
        await (complete ? repo.completeTask(id) : repo.reopenTask(id));
      }
    } catch (_) {
      // Mutation failed server-side; fall through and resync the snapshot so
      // the widget reflects real state rather than a false optimistic flip.
    }

    await _refreshSnapshot();
  }

  /// Refetches the current user's assigned rows and rewrites the widget
  /// snapshot, reusing the same grouping/ordering the live Today screen uses.
  Future<void> _refreshSnapshot() async {
    final households = await HouseholdRepository(
      supabaseClient,
    ).fetchActiveHouseholds();
    final householdNames = {for (final h in households) h.id: h.name};

    final today = TodayRepository(supabaseClient);
    final occRows = await today.fetchAssignedOccurrenceRows();
    final taskRows = await today.fetchAssignedTaskRows();

    final now = DateTime.now();
    final built = buildTodayEntries(
      occRows: occRows,
      taskRows: taskRows,
      householdNames: householdNames,
      now: now,
    );
    final sections = groupTodayEntries(built.active, now);
    await WidgetSnapshotService.update(
      sections: sections,
      completedToday: built.completedToday,
      now: now,
    );
  }
}
