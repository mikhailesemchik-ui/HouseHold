import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

TodayEntry makeEntry({
  required String taskId,
  required String title,
  required String householdName,
  DateTime? scheduledAt,
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

  // ---------------------------------------------------------------------------
  group('WidgetSnapshotService.buildRows', () {
    test('returns empty list when all sections are empty', () {
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(),
        now: now,
      );
      expect(rows, isEmpty);
    });

    test('prioritises overdue over today over upcoming', () {
      final todayMidnight = DateTime(2026, 8, 27, 9, 0);
      final overdueTime = DateTime(2026, 8, 26, 18, 0);
      final upcomingTime = DateTime(2026, 8, 28, 10, 0);

      final rows = WidgetSnapshotService.buildRows(
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
              scheduledAt: todayMidnight,
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
        now: now,
      );

      expect(rows.length, 3);
      expect(rows[0].title, 'Overdue');
      expect(rows[1].title, 'Today');
      expect(rows[2].title, 'Upcoming');
    });

    test('caps rows at 3 regardless of section size', () {
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
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(today: entries),
        now: now,
      );
      expect(rows.length, 3);
    });

    test('does not include anytime entries', () {
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          anytime: [
            makeEntry(
              taskId: 'a',
              title: 'Anytime task',
              householdName: 'H',
              sourceType: TodayEntrySource.anytime,
            ),
          ],
        ),
        now: now,
      );
      expect(rows, isEmpty);
    });

    test('formats time correctly for a today entry', () {
      final scheduledAt = DateTime(2026, 8, 27, 18, 30).toUtc();
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          today: [
            makeEntry(
              taskId: 't',
              title: 'Dinner',
              householdName: 'Home',
              scheduledAt: scheduledAt,
            ),
          ],
        ),
        now: now,
      );
      expect(rows.first.detail, contains('Home'));
      // Time portion should contain 18:30 (assuming test runs in UTC environment)
      // or another valid time — we just check it has hours:minutes format
      expect(rows.first.detail, matches(r'Home · \d{2}:\d{2}'));
    });

    test('formats Tomorrow for an upcoming entry the next day', () {
      final scheduledAt = DateTime(2026, 8, 28, 10, 0).toUtc();
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          upcoming: [
            makeEntry(
              taskId: 'u',
              title: 'Buy milk',
              householdName: 'Parents',
              scheduledAt: scheduledAt,
            ),
          ],
        ),
        now: now,
      );
      expect(rows.first.detail, 'Parents · Tomorrow');
    });

    test('formats Yesterday for an overdue entry one day ago', () {
      final scheduledAt = DateTime(2026, 8, 26, 10, 0).toUtc();
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          overdue: [
            makeEntry(
              taskId: 'o',
              title: 'Trash',
              householdName: 'Home',
              scheduledAt: scheduledAt,
            ),
          ],
        ),
        now: now,
      );
      expect(rows.first.detail, 'Home · Yesterday');
    });

    test('formats weekday + date for entries more than 2 days away', () {
      final scheduledAt = DateTime(2026, 9, 5, 10, 0).toUtc();
      final rows = WidgetSnapshotService.buildRows(
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
        now: now,
      );
      // Expect pattern like "Sat 5 Sep"
      expect(rows.first.detail, matches(r'H · \w{3} \d+ \w{3}'));
    });

    test('row detail includes household name', () {
      final t = DateTime(2026, 8, 27, 9, 0).toUtc();
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          today: [
            makeEntry(
              taskId: 't',
              title: 'T',
              householdName: 'Parents',
              scheduledAt: t,
            ),
          ],
        ),
        now: now,
      );
      expect(rows.first.detail, startsWith('Parents · '));
    });

    test('fills from multiple sections up to 3 total', () {
      final t = DateTime(2026, 8, 27, 9, 0).toUtc();
      final rows = WidgetSnapshotService.buildRows(
        sections: sections(
          overdue: [
            makeEntry(
              taskId: 'o',
              title: 'O',
              householdName: 'H',
              scheduledAt: t,
            ),
          ],
          today: [
            makeEntry(
              taskId: 't',
              title: 'T',
              householdName: 'H',
              scheduledAt: t,
            ),
          ],
          upcoming: [
            makeEntry(
              taskId: 'u1',
              title: 'U1',
              householdName: 'H',
              scheduledAt: t.add(const Duration(days: 2)),
            ),
            makeEntry(
              taskId: 'u2',
              title: 'U2',
              householdName: 'H',
              scheduledAt: t.add(const Duration(days: 3)),
            ),
          ],
        ),
        now: now,
      );
      expect(rows.length, 3);
      expect(rows[0].title, 'O');
      expect(rows[1].title, 'T');
      expect(rows[2].title, 'U1');
    });
  });
}
