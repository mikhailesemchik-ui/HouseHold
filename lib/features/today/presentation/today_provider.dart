import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/notification_service.dart';
import 'package:household_os/core/services/realtime_recovery.dart';
import 'package:household_os/core/services/reminder_coordinator.dart';
import 'package:household_os/core/services/recurring_occurrence_refresher.dart';
import 'package:household_os/core/services/reminder_settings.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/data/today_repository.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

/// Groups [entries] into dashboard sections using [now]'s local day boundaries.
///
/// Returns a map with keys: 'overdue', 'today', 'upcoming', 'anytime'.
/// All four keys are always present; values may be empty lists.
/// Upcoming is capped at 10 entries.
Map<String, List<TodayEntry>> groupTodayEntries(
  List<TodayEntry> entries,
  DateTime now,
) {
  final todayStart = DateTime(now.year, now.month, now.day).toUtc();
  final tomorrowStart = DateTime(now.year, now.month, now.day + 1).toUtc();

  final overdue = <TodayEntry>[];
  final today = <TodayEntry>[];
  final upcoming = <TodayEntry>[];
  final anytime = <TodayEntry>[];

  for (final entry in entries) {
    if (entry.scheduledAt == null) {
      anytime.add(entry);
    } else if (entry.scheduledAt!.isBefore(todayStart)) {
      overdue.add(entry);
    } else if (entry.scheduledAt!.isBefore(tomorrowStart)) {
      today.add(entry);
    } else {
      upcoming.add(entry);
    }
  }

  overdue.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
  today.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
  upcoming.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));

  return {
    'overdue': overdue,
    'today': today,
    'upcoming': upcoming.take(10).toList(),
    'anytime': anytime,
  };
}

/// True when [utc] falls on the same local calendar day as [now].
bool _isLocalToday(DateTime utc, DateTime now) {
  final local = utc.toLocal();
  return local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
}

/// Builds active entries and today's completed entries from raw Supabase
/// rows. Shared by the live Today screen and the widget's background action
/// handler so both read the same assignment/completion rules.
({List<TodayEntry> active, List<TodayEntry> completedToday}) buildTodayEntries({
  required List<Map<String, dynamic>> occRows,
  required List<Map<String, dynamic>> taskRows,
  required Map<String, String> householdNames,
  required DateTime now,
}) {
  final taskLookup = <String, Map<String, dynamic>>{
    for (final row in taskRows) row['id'] as String: row,
  };

  final active = <TodayEntry>[];
  final completedToday = <TodayEntry>[];

  for (final row in occRows) {
    final taskId = row['task_id'] as String;
    final task = taskLookup[taskId];
    if (task == null) continue;
    final householdId = row['household_id'] as String;
    final completedAtRaw = row['completed_at'] as String?;
    final entry = TodayEntry(
      occurrenceId: row['id'] as String,
      taskId: taskId,
      title: task['title'] as String,
      householdId: householdId,
      householdName: householdNames[householdId] ?? householdId,
      scheduledAt: DateTime.parse(row['scheduled_at'] as String),
      recurrenceType: RecurrenceType.parse(
        (task['recurrence_type'] as String?) ?? 'none',
      ),
      sourceType: TodayEntrySource.occurrence,
      completedAt: completedAtRaw == null
          ? null
          : DateTime.parse(completedAtRaw),
    );
    if (completedAtRaw == null) {
      active.add(entry);
    } else if (_isLocalToday(entry.completedAt!, now)) {
      completedToday.add(entry);
    }
  }

  for (final row in taskRows) {
    if (row['due_at'] != null) continue;
    final householdId = row['household_id'] as String;
    final completedAtRaw = row['completed_at'] as String?;
    final entry = TodayEntry(
      occurrenceId: null,
      taskId: row['id'] as String,
      title: row['title'] as String,
      householdId: householdId,
      householdName: householdNames[householdId] ?? householdId,
      scheduledAt: null,
      recurrenceType: RecurrenceType.none,
      sourceType: TodayEntrySource.anytime,
      completedAt: completedAtRaw == null
          ? null
          : DateTime.parse(completedAtRaw),
    );
    if (completedAtRaw == null) {
      active.add(entry);
    } else if (_isLocalToday(entry.completedAt!, now)) {
      completedToday.add(entry);
    }
  }

  return (active: active, completedToday: completedToday);
}

/// Overridable in tests; the real one talks to Supabase.
final todayRepositoryProvider = Provider<TodayRepository>(
  (ref) => TodayRepository(supabaseClient),
);

/// Delay before a failed Today stream is reopened (doubles per attempt);
/// overridable so tests need not wait seconds.
final todayRetryDelayProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

class TodayNotifier extends AsyncNotifier<Map<String, List<TodayEntry>>> {
  // Today is built from two streams. A stream is "stale" from the moment it
  // gives up (recoveringStream used all its retries) until it delivers a fresh
  // snapshot. Opening a stream again, resuming the app or a Retry never clears
  // it, only data does, and the flags outlive a provider rebuild (Retry) so
  // the warning cannot vanish while the new streams are still failing. A
  // disposed provider takes its flags with it, so another user starts clean.
  bool _occurrencesStale = false;
  bool _tasksStale = false;
  final ValueNotifier<bool> _stale = ValueNotifier(false);

  /// True while either source may be out of date. The data on screen is the
  /// last successful one.
  ValueListenable<bool> get isStale => _stale;

  void _markStale({bool? occurrences, bool? tasks}) {
    _occurrencesStale = occurrences ?? _occurrencesStale;
    _tasksStale = tasks ?? _tasksStale;
    _stale.value = _occurrencesStale || _tasksStale;
  }

  List<Map<String, dynamic>> _occRows = [];
  List<Map<String, dynamic>> _taskRows = [];
  Map<String, String> _householdNames = {};
  List<TodayEntry> _allEntries = [];
  List<TodayEntry> _completedToday = [];

  @override
  Future<Map<String, List<TodayEntry>>> build() async {
    final households = await ref.watch(homesProvider.future);
    _householdNames = {for (final h in households) h.id: h.name};

    // Fire-and-forget; failure does not erase displayed data.
    ref.read(recurringOccurrenceRefresherProvider).refresh().ignore();

    final repo = ref.read(todayRepositoryProvider);
    final retryDelay = ref.read(todayRetryDelayProvider);

    // recoveringStream reopens a failed stream; once its retries are used up
    // the error arrives here, the last data stays on screen and the source is
    // marked stale (the screen shows a warning).
    final occSub =
        recoveringStream(
          ref,
          repo.watchAssignedOccurrenceRows,
          label: 'today occurrences',
          retryDelay: retryDelay,
        ).listen(
          (rows) {
            _occRows = rows;
            _markStale(occurrences: false);
            if (state is AsyncData) {
              state = AsyncData(_compute());
            }
          },
          onError: (Object e, StackTrace s) =>
              _onStreamFailed(e, occurrences: true),
        );
    final taskSub =
        recoveringStream(
          ref,
          repo.watchAssignedTaskRows,
          label: 'today tasks',
          retryDelay: retryDelay,
        ).listen(
          (rows) {
            _taskRows = rows;
            _markStale(tasks: false);
            if (state is AsyncData) {
              state = AsyncData(_compute());
            }
          },
          onError: (Object e, StackTrace s) => _onStreamFailed(e, tasks: true),
        );

    ref.onDispose(() {
      occSub.cancel();
      taskSub.cancel();
    });

    return _compute();
  }

  void _onStreamFailed(Object error, {bool? occurrences, bool? tasks}) {
    debugPrint('Today stream failed for good: $error');
    _markStale(occurrences: occurrences, tasks: tasks);
  }

  Map<String, List<TodayEntry>> _compute() {
    final now = DateTime.now();
    final built = buildTodayEntries(
      occRows: _occRows,
      taskRows: _taskRows,
      householdNames: _householdNames,
      now: now,
    );

    final sections = groupTodayEntries(built.active, now);
    _allEntries = built.active;
    _completedToday = built.completedToday;
    reconcileReminders().ignore();
    WidgetSnapshotService.update(
      sections: sections,
      completedToday: _completedToday,
      now: now,
    ).ignore();
    return sections;
  }

  /// Pushes current Today data to the home-screen widget.
  /// No-op if Today data is not yet available.
  Future<void> updateWidget() async {
    if (state case AsyncData(:final value)) {
      await WidgetSnapshotService.update(
        sections: value,
        completedToday: _completedToday,
        now: DateTime.now(),
      );
    }
  }

  /// Reconciles scheduled reminders with current occurrence data.
  /// No-op when reminders are disabled.
  Future<void> reconcileReminders() async {
    final enabled = await ReminderSettings.isEnabled();
    // The scope may have been replaced (another user) while settings loaded:
    // this notifier's entries then belong to the previous user.
    if (!enabled || !ref.mounted) return;
    await ReminderCoordinator.runReconciliation(
      service: notificationService,
      entries: _allEntries,
      now: DateTime.now(),
    );
  }
}

final todayProvider =
    AsyncNotifierProvider.autoDispose<
      TodayNotifier,
      Map<String, List<TodayEntry>>
    >(TodayNotifier.new);
