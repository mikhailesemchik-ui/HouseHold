import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

Map<String, List<TodayEntry>> sectionsWithToday(List<TodayEntry> today) => {
  'overdue': const [],
  'today': today,
  'upcoming': const [],
  'anytime': const [],
};

void main() {
  final now = DateTime(2026, 9, 25, 12);
  const window = Duration(seconds: 2);
  late List<int> written;

  // Fake entries only need a length; the writer under test records the count.
  List<TodayEntry> entries(int count) => List.generate(
    count,
    (i) => TodayEntry(
      occurrenceId: 'occ-$i',
      taskId: 'task-$i',
      title: 'Task $i',
      householdId: 'hh',
      householdName: 'HH',
      scheduledAt: now,
      recurrenceType: RecurrenceType.none,
      sourceType: TodayEntrySource.occurrence,
    ),
  );

  Future<void> push(int count) => WidgetSnapshotService.update(
    sections: sectionsWithToday(entries(count)),
    now: now,
  );

  setUp(() {
    written = [];
    WidgetSnapshotService.resetForTest();
    WidgetSnapshotService.writer = (sections, _) async {
      written.add(sections['today']!.length);
    };
  });

  tearDown(WidgetSnapshotService.resetForTest);

  testWidgets('first update writes immediately', (tester) async {
    await push(0);
    expect(written, [0]);
    await tester.pump(window * 3); // drain the cooldown timer
  });

  testWidgets('update inside the window is delivered after it (0 to 1)', (
    tester,
  ) async {
    await push(0);
    await push(1);
    expect(written, [0]);
    await tester.pump(window);
    expect(written, [0, 1]);
    await tester.pump(window * 3); // drain the cooldown timer
  });

  testWidgets('latest skipped update wins and is written once', (tester) async {
    await push(0);
    await push(1);
    await push(2);
    await push(3);
    await tester.pump(window);
    expect(written, [0, 3]);
    await tester.pump(window * 2);
    expect(written, [0, 3]);
    await tester.pump(window * 3); // drain the cooldown timer
  });

  testWidgets('a clearing update inside the window is persisted (1 to 0)', (
    tester,
  ) async {
    await push(1);
    await push(0);
    await tester.pump(window);
    expect(written, [1, 0]);
    await tester.pump(window * 3); // drain the cooldown timer
  });

  testWidgets('update after a quiet window writes immediately again', (
    tester,
  ) async {
    await push(0);
    await tester.pump(window);
    await push(1);
    expect(written, [0, 1]);
    await tester.pump(window * 3); // drain the cooldown timer
  });
}
