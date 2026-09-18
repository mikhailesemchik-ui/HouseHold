import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_screen.dart';

void main() {
  final now = DateTime(2026, 8, 25, 12);

  Task makeTask({
    String id = '1',
    String title = 'Test task',
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
      completedAt: completedAt,
      completedBy: completedBy,
    );
  }

  /// [navBarHeight] wraps the screen in a stand-in for the app shell — the
  /// same `Scaffold(extendBody: true)` + bottom navigation arrangement that
  /// publishes the nav bar's measured height as `MediaQuery.padding.bottom`.
  Widget buildScreen({
    required Stream<List<Task>> tasksStream,
    List<TaskMember> members = const [],
    List<TaskOccurrence> occurrences = const [],
    double? navBarHeight,
  }) {
    const screen = TasksScreen(householdId: 'test-hh');
    return ProviderScope(
      overrides: [
        tasksStreamProvider('test-hh').overrideWith((ref) => tasksStream),
        taskMembersProvider(
          'test-hh',
        ).overrideWith((ref) => Future.value(members)),
        occurrencesStreamProvider(
          'test-hh',
        ).overrideWith((ref) => Stream.value(occurrences)),
      ],
      child: navBarHeight == null
          ? const MaterialApp(home: screen)
          : MaterialApp(
              home: Scaffold(
                extendBody: true,
                bottomNavigationBar: SizedBox(height: navBarHeight),
                body: screen,
              ),
            ),
    );
  }

  group('Task.fromMap', () {
    test('parses an incomplete task', () {
      final map = {
        'id': 'abc',
        'household_id': 'hh',
        'title': 'Buy milk',
        'description': null,
        'assigned_to': null,
        'created_by': 'user1',
        'created_at': '2026-08-25T12:00:00.000Z',
        'updated_at': '2026-08-25T12:00:00.000Z',
        'completed_at': null,
        'completed_by': null,
      };
      final task = Task.fromMap(map);
      expect(task.id, 'abc');
      expect(task.title, 'Buy milk');
      expect(task.isCompleted, isFalse);
      expect(task.completedAt, isNull);
    });

    test('parses a completed task', () {
      final map = {
        'id': 'def',
        'household_id': 'hh',
        'title': 'Clean kitchen',
        'description': 'Including stove',
        'assigned_to': 'user2',
        'created_by': 'user1',
        'created_at': '2026-08-25T10:00:00.000Z',
        'updated_at': '2026-08-25T11:00:00.000Z',
        'completed_at': '2026-08-25T11:00:00.000Z',
        'completed_by': 'user2',
      };
      final task = Task.fromMap(map);
      expect(task.isCompleted, isTrue);
      expect(task.completedBy, 'user2');
      expect(task.description, 'Including stove');
      expect(task.assignedTo, 'user2');
    });
  });

  group('Task.isCompleted', () {
    test('is false when completedAt is null', () {
      expect(makeTask().isCompleted, isFalse);
    });

    test('is true when completedAt is set', () {
      expect(
        makeTask(completedAt: now, completedBy: 'user1').isCompleted,
        isTrue,
      );
    });
  });

  group('TaskRepository.validateTitle', () {
    test('returns error for empty string', () {
      expect(TaskRepository.validateTitle(''), isNotNull);
    });

    test('returns error for whitespace-only string', () {
      expect(TaskRepository.validateTitle('   '), isNotNull);
    });

    test('returns null for a valid title', () {
      expect(TaskRepository.validateTitle('Buy groceries'), isNull);
    });

    test('returns null for a single-character title', () {
      expect(TaskRepository.validateTitle('X'), isNull);
    });
  });

  group('TasksScreen widget', () {
    testWidgets('shows empty state when there are no tasks', (tester) async {
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value([])));
      await tester.pumpAndSettle();
      expect(find.text('No tasks yet'), findsOneWidget);
    });

    testWidgets('shows task titles in the list', (tester) async {
      final tasks = [
        makeTask(id: '1', title: 'Buy groceries'),
        makeTask(id: '2', title: 'Clean kitchen'),
      ];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();
      expect(find.text('Buy groceries'), findsOneWidget);
      expect(find.text('Clean kitchen'), findsOneWidget);
    });

    testWidgets('completed task title is shown with strikethrough', (
      tester,
    ) async {
      final tasks = [
        makeTask(
          id: '1',
          title: 'Done task',
          completedAt: now,
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();

      final textWidget = tester.widget<Text>(find.text('Done task'));
      expect(textWidget.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('shows skeleton loading state while stream is pending', (
      tester,
    ) async {
      final controller = StreamController<List<Task>>();
      addTearDown(controller.close);
      await tester.pumpWidget(buildScreen(tasksStream: controller.stream));
      await tester.pump();
      expect(find.byType(AppSkeletonList), findsOneWidget);
    });

    testWidgets('empty state offers an Add task action', (tester) async {
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value([])));
      await tester.pumpAndSettle();
      expect(find.text('No tasks yet'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add task'), findsOneWidget);
    });

    testWidgets('long task title does not overflow', (tester) async {
      final tasks = [
        makeTask(
          id: '1',
          title:
              'Deep clean the entire upstairs bathroom including the grout '
              'and the extractor fan above the shower',
        ),
      ];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Deep clean the entire'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('long assignee display name does not overflow', (tester) async {
      final tasks = [makeTask(id: '1', title: 'Water plants')];
      await tester.pumpWidget(
        buildScreen(tasksStream: Stream.value(tasks), members: const []),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unassigned'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('completion control describes the task by name', (
      tester,
    ) async {
      final tasks = [makeTask(id: '1', title: 'Take out trash')];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Mark "Take out trash" as done'),
        findsOneWidget,
      );
    });

    testWidgets('destructive delete confirmation names the task', (
      tester,
    ) async {
      final tasks = [makeTask(id: '1', title: 'Take out trash')];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Task actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete task'));
      await tester.pumpAndSettle();

      expect(find.text('Delete "Take out trash"?'), findsOneWidget);
      // Names the action explicitly — never a bare "Delete" — since deleting
      // an occurrence row actually deletes the whole underlying task.
      expect(find.widgetWithText(FilledButton, 'Delete task'), findsOneWidget);
    });

    testWidgets('delete confirmation explains future-occurrence removal for a '
        'recurring task', (tester) async {
      final tasks = [
        Task(
          id: '1',
          householdId: 'test-hh',
          title: 'Water plants',
          createdBy: 'user1',
          createdAt: now,
          updatedAt: now,
          dueAt: now,
          recurrenceType: RecurrenceType.daily,
        ),
      ];
      await tester.pumpWidget(
        buildScreen(
          tasksStream: Stream.value(tasks),
          occurrences: [
            TaskOccurrence(
              id: 'occ-1',
              taskId: '1',
              householdId: 'test-hh',
              scheduledAt: now.toUtc(),
              createdAt: now.toUtc(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Task actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete task'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This deletes the task and all its future occurrences. This '
          'cannot be undone.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('list clears the shell navigation exactly once, plus the FAB', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      final tasks = [makeTask(id: '1', title: 'Water plants')];
      await tester.pumpWidget(
        buildScreen(
          tasksStream: Stream.value(tasks),
          navBarHeight: navBarHeight,
        ),
      );
      await tester.pumpAndSettle();

      // This list declares its own padding (it needs room for the FAB), so
      // it opts out of automatic MediaQuery consumption and has to re-apply
      // the nav clearance by hand — exactly once, plus the FAB's own space.
      final listView = tester.widget<ListView>(find.byType(ListView));
      final bottomPadding = (listView.padding! as EdgeInsets).bottom;
      expect(bottomPadding, navBarHeight + kFabClearance);
    });

    testWidgets('FAB sits above the shell navigation', (tester) async {
      const navBarHeight = 64.0;
      final tasks = [makeTask(id: '1', title: 'Water plants')];
      await tester.pumpWidget(
        buildScreen(
          tasksStream: Stream.value(tasks),
          navBarHeight: navBarHeight,
        ),
      );
      await tester.pumpAndSettle();

      final positioned = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(positioned.bottom, greaterThanOrEqualTo(navBarHeight));
    });

    testWidgets('no FAB while the tasks stream is still loading', (
      tester,
    ) async {
      final controller = StreamController<List<Task>>();
      addTearDown(controller.close);
      await tester.pumpWidget(buildScreen(tasksStream: controller.stream));
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('no FAB when the tasks stream errors', (tester) async {
      await tester.pumpWidget(
        buildScreen(tasksStream: Stream.error(Exception('boom'))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets(
      'no FAB on the empty state — it already offers its own Add task action',
      (tester) async {
        await tester.pumpWidget(buildScreen(tasksStream: Stream.value([])));
        await tester.pumpAndSettle();
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Add task'), findsOneWidget);
      },
    );

    testWidgets('FAB is present on a normal populated list', (tester) async {
      final tasks = [makeTask(id: '1', title: 'Water plants')];
      await tester.pumpWidget(buildScreen(tasksStream: Stream.value(tasks)));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets(
      'long title, long assignee name, and schedule/recurrence metadata '
      'render at 2.0x without overflow',
      (tester) async {
        final task = Task(
          id: '1',
          householdId: 'test-hh',
          title:
              'Deep clean the entire upstairs bathroom including the grout '
              'and the extractor fan',
          createdBy: 'user1',
          createdAt: now,
          updatedAt: now,
          dueAt: now.toUtc(),
          recurrenceType: RecurrenceType.weekly,
          assignedTo: 'user-2',
        );
        final occurrence = TaskOccurrence(
          id: 'occ-1',
          taskId: '1',
          householdId: 'test-hh',
          scheduledAt: now.toUtc(),
          createdAt: now.toUtc(),
          assignedTo: 'user-2',
        );
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(2.0),
            ),
            child: buildScreen(
              tasksStream: Stream.value([task]),
              occurrences: [occurrence],
              members: const [
                TaskMember(
                  userId: 'user-2',
                  displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
                  publicId: 'christina#1234',
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('resolveTasksLoadState', () {
    test('tasks stream loading → loading', () {
      final state = resolveTasksLoadState(
        const AsyncValue.loading(),
        const AsyncValue.data(<TaskOccurrence>[]),
      );
      expect(state, TasksLoadState.loading);
    });

    test('tasks stream error → tasksError', () {
      final state = resolveTasksLoadState(
        AsyncValue.error(Exception('boom'), StackTrace.empty),
        const AsyncValue.data(<TaskOccurrence>[]),
      );
      expect(state, TasksLoadState.tasksError);
    });

    test('tasks ready, occurrences still loading → ready', () {
      final state = resolveTasksLoadState(
        const AsyncValue.data(<Task>[]),
        const AsyncValue.loading(),
      );
      expect(state, TasksLoadState.ready);
    });

    test(
      'tasks ready, occurrences errored → still ready (degrades locally)',
      () {
        final state = resolveTasksLoadState(
          const AsyncValue.data(<Task>[]),
          AsyncValue.error(Exception('boom'), StackTrace.empty),
        );
        expect(state, TasksLoadState.ready);
      },
    );

    test('both ready → ready', () {
      final state = resolveTasksLoadState(
        const AsyncValue.data(<Task>[]),
        const AsyncValue.data(<TaskOccurrence>[]),
      );
      expect(state, TasksLoadState.ready);
    });
  });
}
