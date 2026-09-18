import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_screen.dart';

void main() {
  final now = DateTime(2026, 8, 25, 12);
  // Dates guaranteed past / future for deterministic isOverdue tests.
  final pastUtc = DateTime.utc(2000, 1, 1);
  final futureUtc = DateTime.utc(2030, 1, 1);

  TaskOccurrence makeOccurrence({
    String id = 'occ-1',
    String taskId = 'task-1',
    DateTime? scheduledAt,
    DateTime? completedAt,
    String? completedBy,
    String? assignedTo,
  }) {
    return TaskOccurrence(
      id: id,
      taskId: taskId,
      householdId: 'hh',
      scheduledAt: scheduledAt ?? futureUtc,
      createdAt: pastUtc,
      completedAt: completedAt,
      completedBy: completedBy,
      assignedTo: assignedTo,
    );
  }

  Task makeTask({
    String id = 'task-1',
    String title = 'Test task',
    DateTime? dueAt,
    RecurrenceType recurrenceType = RecurrenceType.none,
    DateTime? completedAt,
    String? completedBy,
  }) {
    return Task(
      id: id,
      householdId: 'hh',
      title: title,
      createdBy: 'user1',
      createdAt: now,
      updatedAt: now,
      dueAt: dueAt,
      recurrenceType: recurrenceType,
      completedAt: completedAt,
      completedBy: completedBy,
    );
  }

  // -------------------------------------------------------------------------
  group('RecurrenceType.parse', () {
    test(
      'none',
      () => expect(RecurrenceType.parse('none'), RecurrenceType.none),
    );
    test(
      'daily',
      () => expect(RecurrenceType.parse('daily'), RecurrenceType.daily),
    );
    test(
      'weekly',
      () => expect(RecurrenceType.parse('weekly'), RecurrenceType.weekly),
    );
    test('unknown falls back to none', () {
      expect(RecurrenceType.parse('monthly'), RecurrenceType.none);
    });
    test('empty string falls back to none', () {
      expect(RecurrenceType.parse(''), RecurrenceType.none);
    });
    test('case-sensitive — DAILY does not match', () {
      expect(RecurrenceType.parse('DAILY'), RecurrenceType.none);
    });
  });

  // -------------------------------------------------------------------------
  group('RecurrenceType.label', () {
    test(
      'none label',
      () => expect(RecurrenceType.none.label, 'Does not repeat'),
    );
    test('daily label', () => expect(RecurrenceType.daily.label, 'Daily'));
    test('weekly label', () => expect(RecurrenceType.weekly.label, 'Weekly'));
  });

  // -------------------------------------------------------------------------
  group('Task.fromMap — due date and recurrence fields', () {
    test('parses due_at and recurrence_type', () {
      final map = {
        'id': 't1',
        'household_id': 'hh',
        'title': 'Water plants',
        'description': null,
        'assigned_to': null,
        'created_by': 'user1',
        'created_at': '2026-08-25T12:00:00.000Z',
        'updated_at': '2026-08-25T12:00:00.000Z',
        'completed_at': null,
        'completed_by': null,
        'due_at': '2026-09-01T08:00:00.000Z',
        'recurrence_type': 'daily',
      };
      final task = Task.fromMap(map);
      expect(task.dueAt, DateTime.utc(2026, 9, 1, 8));
      expect(task.recurrenceType, RecurrenceType.daily);
    });

    test('null due_at and missing recurrence_type → defaults', () {
      final map = {
        'id': 't2',
        'household_id': 'hh',
        'title': 'Simple task',
        'description': null,
        'assigned_to': null,
        'created_by': 'user1',
        'created_at': '2026-08-25T12:00:00.000Z',
        'updated_at': '2026-08-25T12:00:00.000Z',
        'completed_at': null,
        'completed_by': null,
        // due_at and recurrence_type absent (legacy row)
      };
      final task = Task.fromMap(map);
      expect(task.dueAt, isNull);
      expect(task.recurrenceType, RecurrenceType.none);
    });

    test('weekly recurrence', () {
      final map = {
        'id': 't3',
        'household_id': 'hh',
        'title': 'Weekly meeting',
        'description': null,
        'assigned_to': null,
        'created_by': 'user1',
        'created_at': '2026-08-25T12:00:00.000Z',
        'updated_at': '2026-08-25T12:00:00.000Z',
        'completed_at': null,
        'completed_by': null,
        'due_at': '2026-08-25T09:00:00.000Z',
        'recurrence_type': 'weekly',
      };
      final task = Task.fromMap(map);
      expect(task.recurrenceType, RecurrenceType.weekly);
    });
  });

  // -------------------------------------------------------------------------
  group('TaskOccurrence.fromMap', () {
    test('parses an incomplete occurrence', () {
      final map = {
        'id': 'occ-1',
        'task_id': 'task-1',
        'household_id': 'hh',
        'scheduled_at': '2026-09-01T08:00:00.000Z',
        'assigned_to': 'user-2',
        'completed_at': null,
        'completed_by': null,
        'created_at': '2026-08-25T12:00:00.000Z',
      };
      final occ = TaskOccurrence.fromMap(map);
      expect(occ.id, 'occ-1');
      expect(occ.taskId, 'task-1');
      expect(occ.scheduledAt, DateTime.utc(2026, 9, 1, 8));
      expect(occ.assignedTo, 'user-2');
      expect(occ.isCompleted, isFalse);
    });

    test('parses a completed occurrence', () {
      final map = {
        'id': 'occ-2',
        'task_id': 'task-1',
        'household_id': 'hh',
        'scheduled_at': '2026-08-20T08:00:00.000Z',
        'assigned_to': null,
        'completed_at': '2026-08-20T09:00:00.000Z',
        'completed_by': 'user-1',
        'created_at': '2026-08-18T12:00:00.000Z',
      };
      final occ = TaskOccurrence.fromMap(map);
      expect(occ.isCompleted, isTrue);
      expect(occ.completedBy, 'user-1');
    });
  });

  // -------------------------------------------------------------------------
  group('TaskOccurrence.isCompleted', () {
    test('false when completedAt is null', () {
      expect(makeOccurrence().isCompleted, isFalse);
    });

    test('true when completedAt is set', () {
      expect(
        makeOccurrence(completedAt: pastUtc, completedBy: 'user1').isCompleted,
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('TaskOccurrence.isOverdue', () {
    test('true for past incomplete occurrence', () {
      expect(makeOccurrence(scheduledAt: pastUtc).isOverdue, isTrue);
    });

    test('false for future incomplete occurrence', () {
      expect(makeOccurrence(scheduledAt: futureUtc).isOverdue, isFalse);
    });

    test('false for past completed occurrence', () {
      expect(
        makeOccurrence(
          scheduledAt: pastUtc,
          completedAt: pastUtc,
          completedBy: 'user1',
        ).isOverdue,
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('Occurrence sort order', () {
    test('overdue → upcoming → completed', () {
      final overdue = makeOccurrence(id: 'overdue', scheduledAt: pastUtc);
      final upcoming = makeOccurrence(id: 'upcoming', scheduledAt: futureUtc);
      final completed = makeOccurrence(
        id: 'completed',
        scheduledAt: pastUtc,
        completedAt: pastUtc,
        completedBy: 'u',
      );
      final list = [completed, upcoming, overdue];
      list.sort((a, b) {
        if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
        return a.scheduledAt.compareTo(b.scheduledAt);
      });
      expect(list.map((o) => o.id), ['overdue', 'upcoming', 'completed']);
    });

    test('two overdue occurrences sorted by scheduledAt', () {
      final earlier = makeOccurrence(
        id: 'earlier',
        scheduledAt: DateTime.utc(2000, 1, 1),
      );
      final later = makeOccurrence(
        id: 'later',
        scheduledAt: DateTime.utc(2001, 1, 1),
      );
      final list = [later, earlier];
      list.sort((a, b) {
        if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
        return a.scheduledAt.compareTo(b.scheduledAt);
      });
      expect(list.map((o) => o.id), ['earlier', 'later']);
    });
  });

  // -------------------------------------------------------------------------
  group('TaskRepository.validateDueRecurrence', () {
    test('none + null dueAt → ok', () {
      expect(
        TaskRepository.validateDueRecurrence(RecurrenceType.none, null),
        isNull,
      );
    });

    test('none + dueAt set → ok', () {
      expect(
        TaskRepository.validateDueRecurrence(RecurrenceType.none, futureUtc),
        isNull,
      );
    });

    test('daily + null dueAt → error', () {
      expect(
        TaskRepository.validateDueRecurrence(RecurrenceType.daily, null),
        isNotNull,
      );
    });

    test('weekly + null dueAt → error', () {
      expect(
        TaskRepository.validateDueRecurrence(RecurrenceType.weekly, null),
        isNotNull,
      );
    });

    test('daily + dueAt set → ok', () {
      expect(
        TaskRepository.validateDueRecurrence(RecurrenceType.daily, futureUtc),
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('TasksScreen — non-due tasks still work', () {
    Widget buildScreen({
      List<Task> tasks = const [],
      List<TaskOccurrence> occurrences = const [],
    }) {
      return ProviderScope(
        overrides: [
          tasksStreamProvider('hh').overrideWith((ref) => Stream.value(tasks)),
          taskMembersProvider(
            'hh',
          ).overrideWith((ref) => Future.value(<TaskMember>[])),
          occurrencesStreamProvider(
            'hh',
          ).overrideWith((ref) => Stream.value(occurrences)),
        ],
        child: const MaterialApp(home: TasksScreen(householdId: 'hh')),
      );
    }

    testWidgets('shows empty state when both lists are empty', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();
      expect(find.text('No tasks yet'), findsOneWidget);
    });

    testWidgets('non-due task appears without due date UI', (tester) async {
      await tester.pumpWidget(
        buildScreen(tasks: [makeTask(title: 'Feed cat')]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Feed cat'), findsOneWidget);
    });

    testWidgets('occurrence row shows task title and scheduled time', (
      tester,
    ) async {
      final task = makeTask(
        id: 'task-1',
        title: 'Water plants',
        dueAt: futureUtc,
        recurrenceType: RecurrenceType.daily,
      );
      final occ = makeOccurrence(
        taskId: 'task-1',
        scheduledAt: DateTime.utc(2030, 1, 1, 9, 0),
      );
      await tester.pumpWidget(buildScreen(tasks: [task], occurrences: [occ]));
      await tester.pumpAndSettle();
      // Title comes from parent task
      expect(find.text('Water plants'), findsOneWidget);
      // Repeat icon present for recurring task
      expect(find.byIcon(Icons.repeat), findsOneWidget);
    });

    testWidgets('a recurring task with no due date still shows the repeat cue '
        '(regression: hasRecurrence used to be hardcoded false here)', (
      tester,
    ) async {
      final task = makeTask(
        id: 'task-1',
        title: 'Water the office plants',
        dueAt: null,
        recurrenceType: RecurrenceType.weekly,
      );
      await tester.pumpWidget(buildScreen(tasks: [task]));
      await tester.pumpAndSettle();

      expect(find.text('Water the office plants'), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      expect(find.bySemanticsLabel('Repeats weekly'), findsOneWidget);
    });

    testWidgets('a non-due, non-recurring task shows no repeat cue', (
      tester,
    ) async {
      final task = makeTask(id: 'task-1', title: 'Feed cat', dueAt: null);
      await tester.pumpWidget(buildScreen(tasks: [task]));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.repeat), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('TasksScreen — occurrence stream failure', () {
    Widget buildScreen({
      List<Task> tasks = const [],
      required Stream<List<TaskOccurrence>> occurrencesStream,
    }) {
      return ProviderScope(
        overrides: [
          tasksStreamProvider('hh').overrideWith((ref) => Stream.value(tasks)),
          taskMembersProvider(
            'hh',
          ).overrideWith((ref) => Future.value(<TaskMember>[])),
          occurrencesStreamProvider(
            'hh',
          ).overrideWith((ref) => occurrencesStream),
        ],
        child: const MaterialApp(home: TasksScreen(householdId: 'hh')),
      );
    }

    testWidgets(
      'already-loaded, non-due tasks remain visible when occurrences error',
      (tester) async {
        final task = makeTask(id: 'task-1', title: 'Feed cat', dueAt: null);
        await tester.pumpWidget(
          buildScreen(
            tasks: [task],
            occurrencesStream: Stream.error(Exception('boom')),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Feed cat'), findsOneWidget);
        expect(find.text('Could not load scheduled tasks.'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      },
    );
  });
}
