import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/reminder_coordinator.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

TodayEntry makeEntry({
  String? occurrenceId = 'occ-1',
  String taskId = 'task-1',
  String title = 'Test task',
  String householdId = 'hh-1',
  String householdName = 'Home',
  DateTime? scheduledAt,
  TodayEntrySource sourceType = TodayEntrySource.occurrence,
}) {
  return TodayEntry(
    occurrenceId: occurrenceId,
    taskId: taskId,
    title: title,
    householdId: householdId,
    householdName: householdName,
    scheduledAt: scheduledAt,
    recurrenceType: RecurrenceType.none,
    sourceType: sourceType,
  );
}

void main() {
  final now = DateTime.utc(2026, 8, 27, 12);
  final future = now.add(const Duration(hours: 2));
  final past = now.subtract(const Duration(hours: 2));

  // ---------------------------------------------------------------------------
  group('ReminderCoordinator.notificationId', () {
    test('returns a non-negative int', () {
      final id = ReminderCoordinator.notificationId('some-uuid');
      expect(id, greaterThanOrEqualTo(0));
    });

    test('fits within positive 31-bit range', () {
      final id = ReminderCoordinator.notificationId('some-uuid');
      expect(id, lessThan(1 << 31));
    });

    test('is deterministic for the same input', () {
      const uuid = 'abc-123-def-456';
      expect(
        ReminderCoordinator.notificationId(uuid),
        ReminderCoordinator.notificationId(uuid),
      );
    });

    test('produces different IDs for different inputs', () {
      final id1 = ReminderCoordinator.notificationId('uuid-alpha');
      final id2 = ReminderCoordinator.notificationId('uuid-beta');
      expect(id1, isNot(equals(id2)));
    });

    test('handles empty string without throwing', () {
      expect(() => ReminderCoordinator.notificationId(''), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  group('ReminderCoordinator.targetsFromEntries', () {
    test('includes a future occurrence entry', () {
      final entry = makeEntry(scheduledAt: future);
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets.length, 1);
      expect(targets.first.occurrenceId, 'occ-1');
    });

    test('excludes a past occurrence entry', () {
      final entry = makeEntry(scheduledAt: past);
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('excludes an entry scheduled exactly at now', () {
      final entry = makeEntry(scheduledAt: now);
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('excludes an anytime entry (null scheduledAt)', () {
      final entry = makeEntry(
        scheduledAt: null,
        sourceType: TodayEntrySource.anytime,
        occurrenceId: null,
      );
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('excludes an anytime sourceType entry even with scheduledAt', () {
      final entry = makeEntry(
        scheduledAt: future,
        sourceType: TodayEntrySource.anytime,
      );
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('excludes an entry with null occurrenceId', () {
      final entry = makeEntry(scheduledAt: future, occurrenceId: null);
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('filters correctly across a mixed list', () {
      final entries = [
        makeEntry(
          occurrenceId: 'future',
          taskId: 'future',
          scheduledAt: future,
        ),
        makeEntry(occurrenceId: 'past', taskId: 'past', scheduledAt: past),
        makeEntry(
          occurrenceId: null,
          taskId: 'anytime',
          scheduledAt: null,
          sourceType: TodayEntrySource.anytime,
        ),
      ];
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: entries,
        now: now,
      );
      expect(targets.length, 1);
      expect(targets.first.occurrenceId, 'future');
    });

    test('returns empty for empty input', () {
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [],
        now: now,
      );
      expect(targets, isEmpty);
    });

    test('target carries correct householdId for navigation', () {
      final entry = makeEntry(
        scheduledAt: future,
        householdId: 'hh-999',
        householdName: 'My Home',
      );
      final targets = ReminderCoordinator.targetsFromEntries(
        entries: [entry],
        now: now,
      );
      expect(targets.first.householdId, 'hh-999');
      expect(targets.first.householdName, 'My Home');
    });
  });

  // ---------------------------------------------------------------------------
  group('ReminderCoordinator.reconcile', () {
    ReminderTarget makeTarget(String occurrenceId) {
      return ReminderTarget(
        occurrenceId: occurrenceId,
        title: 'Task',
        householdName: 'Home',
        householdId: 'hh-1',
        scheduledAt: future,
      );
    }

    test('schedules targets whose IDs are not in currentlyScheduledIds', () {
      final target = makeTarget('new-occ');
      final result = ReminderCoordinator.reconcile(
        targets: [target],
        currentlyScheduledIds: {},
      );
      expect(result.toSchedule, [target]);
      expect(result.toCancel, isEmpty);
    });

    test('does not reschedule a target already in currentlyScheduledIds', () {
      final target = makeTarget('existing-occ');
      final id = ReminderCoordinator.notificationId('existing-occ');
      final result = ReminderCoordinator.reconcile(
        targets: [target],
        currentlyScheduledIds: {id},
      );
      expect(result.toSchedule, isEmpty);
      expect(result.toCancel, isEmpty);
    });

    test('cancels IDs that are no longer in targets', () {
      const staleId = 9999;
      final result = ReminderCoordinator.reconcile(
        targets: [],
        currentlyScheduledIds: {staleId},
      );
      expect(result.toCancel, [staleId]);
      expect(result.toSchedule, isEmpty);
    });

    test('empty targets + empty currentIds → nothing to do', () {
      final result = ReminderCoordinator.reconcile(
        targets: [],
        currentlyScheduledIds: {},
      );
      expect(result.toSchedule, isEmpty);
      expect(result.toCancel, isEmpty);
    });

    test('schedules new and cancels stale simultaneously', () {
      final newTarget = makeTarget('new-occ');
      const staleId = 8888;
      final result = ReminderCoordinator.reconcile(
        targets: [newTarget],
        currentlyScheduledIds: {staleId},
      );
      expect(result.toSchedule, [newTarget]);
      expect(result.toCancel, [staleId]);
    });

    test('multiple targets — only missing ones are scheduled', () {
      final existing = makeTarget('existing-occ');
      final newTarget = makeTarget('new-occ');
      final existingId = ReminderCoordinator.notificationId('existing-occ');
      final result = ReminderCoordinator.reconcile(
        targets: [existing, newTarget],
        currentlyScheduledIds: {existingId},
      );
      expect(result.toSchedule, [newTarget]);
      expect(result.toCancel, isEmpty);
    });
  });
}
