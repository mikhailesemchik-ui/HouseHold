import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

TodayEntry makeEntry({
  required String taskId,
  required String title,
  required String householdName,
  DateTime? scheduledAt,
  DateTime? completedAt,
  TodayEntrySource sourceType = TodayEntrySource.occurrence,
}) {
  return TodayEntry(
    occurrenceId: sourceType == TodayEntrySource.occurrence
        ? 'occ-$taskId'
        : null,
    taskId: taskId,
    title: title,
    householdId: 'hh-1',
    householdName: householdName,
    scheduledAt: scheduledAt,
    recurrenceType: RecurrenceType.none,
    sourceType: sourceType,
    completedAt: completedAt,
  );
}

Map<String, List<TodayEntry>> sections({
  List<TodayEntry> overdue = const [],
  List<TodayEntry> today = const [],
  List<TodayEntry> upcoming = const [],
  List<TodayEntry> anytime = const [],
}) {
  return {
    'overdue': overdue,
    'today': today,
    'upcoming': upcoming,
    'anytime': anytime,
  };
}

void main() {
  final now = DateTime(2026, 8, 27, 12, 0); // local noon

  group('WidgetSnapshotService.buildItems', () {
    test('returns empty list when nothing is assigned', () {
      final items = WidgetSnapshotService.buildItems(
        sections: sections(),
        completedToday: const [],
        now: now,
      );
      expect(items, isEmpty);
    });

    test('orders overdue, then today, then anytime, then upcoming', () {
      final overdueTime = DateTime(2026, 8, 26, 18, 0);
      final todayTime = DateTime(2026, 8, 27, 9, 0);
      final upcomingTime = DateTime(2026, 8, 28, 10, 0);

      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          overdue: [
            makeEntry(
              taskId: 'o',
              title: 'Overdue',
              householdName: 'H',
              scheduledAt: overdueTime,
            ),
          ],
          today: [
            makeEntry(
              taskId: 't',
              title: 'Today',
              householdName: 'H',
              scheduledAt: todayTime,
            ),
          ],
          anytime: [
            makeEntry(
              taskId: 'a',
              title: 'Anytime',
              householdName: 'H',
              sourceType: TodayEntrySource.anytime,
            ),
          ],
          upcoming: [
            makeEntry(
              taskId: 'u',
              title: 'Upcoming',
              householdName: 'H',
              scheduledAt: upcomingTime,
            ),
          ],
        ),
        completedToday: const [],
        now: now,
      );

      expect(items.map((e) => e.title).toList(), [
        'Overdue',
        'Today',
        'Anytime',
        'Upcoming',
      ]);
      expect(items[0].label, 'Overdue');
      expect(items[1].label, 'Today');
      expect(items[2].label, 'Anytime');
    });

    test('does not cap the list at 3 rows', () {
      final t = DateTime(2026, 8, 27, 9, 0);
      final entries = List.generate(
        6,
        (i) => makeEntry(
          taskId: 'e$i',
          title: 'Task $i',
          householdName: 'H',
          scheduledAt: t,
        ),
      );
      final items = WidgetSnapshotService.buildItems(
        sections: sections(today: entries),
        completedToday: const [],
        now: now,
      );
      expect(items.length, 6);
    });

    test('completed-today entries sort after all active entries', () {
      final activeTime = DateTime(2026, 8, 27, 9, 0);
      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          today: [
            makeEntry(
              taskId: 't',
              title: 'Active',
              householdName: 'H',
              scheduledAt: activeTime,
            ),
          ],
        ),
        completedToday: [
          makeEntry(
            taskId: 'c',
            title: 'Completed',
            householdName: 'H',
            scheduledAt: activeTime,
            completedAt: DateTime(2026, 8, 27, 8, 0),
          ),
        ],
        now: now,
      );
      expect(items.map((e) => e.title).toList(), ['Active', 'Completed']);
      expect(items.last.completed, isTrue);
      // Real due-bucket label, not a hardcoded "Done" — activeTime falls on
      // the same day as `now`, so this completed entry's true bucket is
      // "Today" (the same one it would land in if it were reopened).
      expect(items.last.label, 'Today');
    });

    test('most recently completed-today task sorts first among completed', () {
      final items = WidgetSnapshotService.buildItems(
        sections: sections(),
        completedToday: [
          makeEntry(
            taskId: 'early',
            title: 'Early',
            householdName: 'H',
            completedAt: DateTime(2026, 8, 27, 8, 0),
          ),
          makeEntry(
            taskId: 'late',
            title: 'Late',
            householdName: 'H',
            completedAt: DateTime(2026, 8, 27, 11, 0),
          ),
        ],
        now: now,
      );
      expect(items.map((e) => e.title).toList(), ['Late', 'Early']);
    });

    test('item id uses occurrenceId for scheduled entries', () {
      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          today: [
            makeEntry(
              taskId: 't1',
              title: 'T',
              householdName: 'H',
              scheduledAt: now,
            ),
          ],
        ),
        completedToday: const [],
        now: now,
      );
      expect(items.single.id, 'occ-t1');
      expect(items.single.source, 'occurrence');
    });

    test('item id uses taskId for anytime entries', () {
      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          anytime: [
            makeEntry(
              taskId: 't2',
              title: 'T',
              householdName: 'H',
              sourceType: TodayEntrySource.anytime,
            ),
          ],
        ),
        completedToday: const [],
        now: now,
      );
      expect(items.single.id, 't2');
      expect(items.single.source, 'anytime');
    });

    test('formats weekday + date for an upcoming entry', () {
      final scheduledAt = DateTime(2026, 9, 5, 10, 0).toUtc();
      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          upcoming: [
            makeEntry(
              taskId: 'f',
              title: 'Future',
              householdName: 'H',
              scheduledAt: scheduledAt,
            ),
          ],
        ),
        completedToday: const [],
        now: now,
      );
      expect(items.first.label, matches(r'\w{3} \d+ \w{3}'));
    });

    test('long titles with quotes/unicode survive a JSON round trip', () {
      final items = WidgetSnapshotService.buildItems(
        sections: sections(
          today: [
            makeEntry(
              taskId: 't',
              title: List.filled(
                3,
                'Deep clean the "upstairs" bathroom — grout, fan & tiles ★',
              ).join(' '),
              householdName: 'H',
              scheduledAt: now,
            ),
          ],
        ),
        completedToday: const [],
        now: now,
      );
      final encoded = jsonEncode(items.map((e) => e.toJson()).toList());
      final decoded = jsonDecode(encoded) as List<dynamic>;
      expect(decoded.single['title'], items.single.title);
    });
  });
}
