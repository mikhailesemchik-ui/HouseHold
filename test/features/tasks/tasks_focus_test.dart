import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_screen.dart';

// Opening Tasks from Today used to lose the tapped task. The screen now takes
// the task (and, for a scheduled one, its occurrence) and scrolls to that row.
void main() {
  final created = DateTime.utc(2026, 10, 1);

  Task task(String id, String title, {DateTime? dueAt, bool weekly = false}) =>
      Task(
        id: id,
        householdId: 'hh',
        title: title,
        createdBy: 'u',
        createdAt: created,
        updatedAt: created,
        dueAt: dueAt,
        recurrenceType: weekly ? RecurrenceType.weekly : RecurrenceType.none,
      );

  TaskOccurrence occurrence(
    String id,
    String taskId,
    DateTime at, {
    bool done = false,
  }) => TaskOccurrence(
    id: id,
    taskId: taskId,
    householdId: 'hh',
    scheduledAt: at,
    createdAt: created,
    completedAt: done ? created : null,
    completedBy: done ? 'u' : null,
  );

  final start = DateTime.utc(2026, 11, 6, 11, 49);
  final chores = [for (var i = 1; i <= 14; i++) task('chore-$i', 'Chore $i')];
  final weekly = task('weekly', 'Water plants', dueAt: start, weekly: true);
  final tasks = [...chores, weekly];
  final weeklyOccurrences = [
    for (var i = 0; i < 12; i++)
      occurrence('occ-${i + 1}', 'weekly', start.add(Duration(days: 7 * i))),
  ];

  group('resolveFocusedRow', () {
    ({String? occurrenceId, String? taskId})? resolve({
      String? taskId,
      String? occurrenceId,
      List<Task>? among,
      List<TaskOccurrence>? occurrences,
    }) => resolveFocusedRow(
      taskId: taskId,
      occurrenceId: occurrenceId,
      tasks: among ?? tasks,
      occurrences: occurrences ?? weeklyOccurrences,
    );

    test('a scheduled task opens its own occurrence, not just the task', () {
      final row = resolve(taskId: 'weekly', occurrenceId: 'occ-5');
      expect(row?.occurrenceId, 'occ-5');
      expect(row?.taskId, isNull);
    });

    test('an occurrence id is never accepted as a task id', () {
      expect(resolve(taskId: 'occ-5'), isNull);
    });

    test('an occurrence of a different task is never used', () {
      final row = resolve(taskId: 'chore-1', occurrenceId: 'occ-5');
      expect(row?.occurrenceId, isNull);
      expect(row?.taskId, 'chore-1', reason: 'falls back to the task itself');
    });

    test('a task without a due date opens its own row', () {
      final row = resolve(taskId: 'chore-9');
      expect(row?.taskId, 'chore-9');
      expect(row?.occurrenceId, isNull);
    });

    test(
      'a scheduled task without an occurrence id opens its next open one',
      () {
        final done = [
          occurrence('occ-1', 'weekly', start, done: true),
          ...weeklyOccurrences.skip(1),
        ];
        expect(
          resolve(taskId: 'weekly', occurrences: done)?.occurrenceId,
          'occ-2',
        );
      },
    );

    test('an unknown or other household task is not found', () {
      expect(resolve(taskId: 'other-household-task'), isNull);
      expect(
        resolve(taskId: 'other-household-task', occurrenceId: 'occ-other'),
        isNull,
      );
    });

    test('while occurrences are still loading a scheduled target is not '
        'resolved yet, but a plain task already is', () {
      expect(
        resolveFocusedRow(
          taskId: 'weekly',
          occurrenceId: 'occ-5',
          tasks: tasks,
          occurrences: null,
        ),
        isNull,
      );
      expect(
        resolveFocusedRow(
          taskId: 'chore-3',
          occurrenceId: null,
          tasks: tasks,
          occurrences: null,
        )?.taskId,
        'chore-3',
      );
    });
  });

  group('TasksScreen opened for one task', () {
    late StreamController<List<TaskOccurrence>> occurrencesController;

    setUp(() {
      occurrencesController = StreamController<List<TaskOccurrence>>();
      addTearDown(occurrencesController.close);
    });

    Widget app({
      String? taskId,
      String? occurrenceId,
      bool occurrencesNow = true,
    }) {
      if (occurrencesNow) occurrencesController.add(weeklyOccurrences);
      return ProviderScope(
        overrides: [
          tasksStreamProvider('hh').overrideWith((ref) => Stream.value(tasks)),
          taskMembersProvider(
            'hh',
          ).overrideWith((ref) => Future.value(<TaskMember>[])),
          occurrencesStreamProvider(
            'hh',
          ).overrideWith((ref) => occurrencesController.stream),
        ],
        child: MaterialApp(
          home: TasksScreen(
            householdId: 'hh',
            focusTaskId: taskId,
            focusOccurrenceId: occurrenceId,
          ),
        ),
      );
    }

    Future<void> small(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    // The outlined row: the foreground border only the highlight draws.
    Finder outline() => find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.position == DecorationPosition.foreground &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border != null,
    );

    /// Text inside the outlined row (rows off screen are not built, so the
    /// row is identified by what it shows, not by its position).
    Finder inOutline(String text) =>
        find.descendant(of: outline(), matching: find.text(text));

    // Same wording as the Tasks list for a scheduled row.
    String when(int occurrenceNumber) {
      final dt = start
          .add(Duration(days: 7 * (occurrenceNumber - 1)))
          .toLocal();
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '${months[dt.month - 1]} ${dt.day} · $h:$m';
    }

    double scrollOffset(WidgetTester tester) => tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;

    testWidgets('a far-down occurrence is scrolled into view and outlined', (
      tester,
    ) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'weekly', occurrenceId: 'occ-12'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(outline(), findsOneWidget);
      expect(inOutline(when(12)), findsOneWidget);
      final frame = tester.getRect(outline());
      expect(frame.top, greaterThanOrEqualTo(0));
      expect(frame.bottom, lessThanOrEqualTo(700));
      expect(scrollOffset(tester), greaterThan(0));
    });

    testWidgets('a different occurrence of the same task opens that one', (
      tester,
    ) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'weekly', occurrenceId: 'occ-3'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(outline(), findsOneWidget);
      expect(inOutline(when(3)), findsOneWidget);
    });

    testWidgets('a task without a due date opens its own row', (tester) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'chore-11'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(outline(), findsOneWidget);
      expect(inOutline('Chore 11'), findsOneWidget);
    });

    testWidgets('without a target nothing scrolls, nothing is outlined and no '
        'message appears', (tester) async {
      await small(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(outline(), findsNothing);
      expect(scrollOffset(tester), 0);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the target survives data that arrives after the screen '
        'opens', (tester) async {
      await small(tester);
      await tester.pumpWidget(
        app(taskId: 'weekly', occurrenceId: 'occ-12', occurrencesNow: false),
      );
      await tester.pump();
      await tester.pump();

      expect(outline(), findsNothing);
      expect(find.byType(SnackBar), findsNothing, reason: 'still loading');

      occurrencesController.add(weeklyOccurrences);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(outline(), findsOneWidget);
      expect(inOutline(when(12)), findsOneWidget);
    });

    testWidgets('a task that is not in this household says so and outlines '
        'nothing', (tester) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'task-of-another-household'));
      await tester.pumpAndSettle();

      expect(find.text('That task is no longer available.'), findsOneWidget);
      expect(outline(), findsNothing);
      expect(scrollOffset(tester), 0);
    });

    testWidgets('the outline fades, and the screen is not pulled back by later '
        'updates', (tester) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'weekly', occurrenceId: 'occ-12'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(outline(), findsOneWidget);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(scrollOffset(tester), 0, reason: 'the user scrolled back up');

      occurrencesController.add([...weeklyOccurrences]); // a live update
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(scrollOffset(tester), 0, reason: 'no repeated scrolling');

      await tester.pump(const Duration(seconds: 4));
      expect(outline(), findsNothing);
    });

    testWidgets('opening it again for another task moves to that one', (
      tester,
    ) async {
      await small(tester);
      await tester.pumpWidget(app(taskId: 'weekly', occurrenceId: 'occ-12'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(inOutline(when(12)), findsOneWidget);

      await tester.pumpWidget(app(taskId: 'weekly', occurrenceId: 'occ-2'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(outline(), findsOneWidget);
      expect(inOutline(when(2)), findsOneWidget);
    });
  });
}
