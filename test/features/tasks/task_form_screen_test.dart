import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/presentation/task_form_screen.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

void main() {
  const members = [
    TaskMember(userId: 'u1', displayName: 'Alice', publicId: 'alice#1'),
    TaskMember(userId: 'u2', displayName: 'Bob', publicId: 'bob#2'),
  ];

  Widget buildForm({
    Task? existingTask,
    AsyncValue<List<TaskMember>>? membersOverride,
  }) {
    return ProviderScope(
      overrides: [
        if (membersOverride == null)
          taskMembersProvider('hh').overrideWith((ref) async => members)
        else
          taskMembersProvider('hh').overrideWith((ref) {
            return switch (membersOverride) {
              AsyncData(:final value) => Future.value(value),
              AsyncError(:final error) => Future<List<TaskMember>>.error(error),
              _ => Completer<List<TaskMember>>().future,
            };
          }),
      ],
      child: MaterialApp(
        theme: appTheme,
        home: TaskFormScreen(householdId: 'hh', existingTask: existingTask),
      ),
    );
  }

  /// Pushes the form on a real navigator (with a previous route to pop back
  /// to) so the AppBar back button and system-back dirty-state prompt are
  /// actually exercisable, not just inspectable via `PopScope.canPop`.
  Widget buildFormPushed({Task? existingTask}) {
    return ProviderScope(
      overrides: [
        taskMembersProvider('hh').overrideWith((ref) async => members),
      ],
      child: MaterialApp(
        theme: appTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TaskFormScreen(
                      householdId: 'hh',
                      existingTask: existingTask,
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('TaskFormScreen — create mode', () {
    testWidgets('renders every field with a Create action', (tester) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();

      expect(find.text('New task'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Create'), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Assign to'), findsOneWidget);
      expect(find.text('Unassigned'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('No due date'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
    });

    testWidgets('recurrence control is disabled without a due date', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<RecurrenceType>>(
        find.byType(SegmentedButton<RecurrenceType>),
      );
      expect(segmented.selected, {RecurrenceType.none});
      expect(segmented.onSelectionChanged, isNull);
      expect(find.text('Set a due date to enable repeat'), findsOneWidget);
    });

    testWidgets('empty title keeps the form open and shows a field error', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pump();

      expect(find.text('Task title cannot be blank'), findsOneWidget);
      expect(find.text('New task'), findsOneWidget);
    });

    testWidgets(
      'mutation failure keeps entered data and leaves the form retry-able',
      (tester) async {
        await tester.pumpWidget(buildForm());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, 'Buy milk');
        await tester.enterText(find.byType(TextField).last, 'From the shop');
        await tester.tap(find.widgetWithText(TextButton, 'Create'));
        await tester.pumpAndSettle();

        // No Supabase client is initialized in this test, so the mutation
        // fails — the regression this guards is that failure must NOT
        // silently close the form or discard what was typed.
        expect(find.text('Buy milk'), findsOneWidget);
        expect(find.text('From the shop'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Create'), findsOneWidget);
      },
    );

    testWidgets(
      'network failure shows a form-level message, not a Title field error',
      (tester) async {
        await tester.pumpWidget(buildForm());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, 'Buy milk');
        await tester.tap(find.widgetWithText(TextButton, 'Create'));
        await tester.pumpAndSettle();

        final titleField = tester.widget<TextField>(
          find.byType(TextField).first,
        );
        expect(titleField.decoration?.errorText, isNull);
        expect(
          find.text('Failed to save task. Please try again.'),
          findsOneWidget,
        );
      },
    );

    // A live double-tap race isn't exercisable here: with no Supabase client
    // initialized in the test process, `TaskRepository(...).createTask(...)`
    // throws synchronously the moment it's awaited, so `_submit` runs its
    // whole setState(true) → fail → setState(false) sequence within one
    // microtask burst — there is no realistic in-flight window a widget test
    // can catch. The guard itself (`if (_isSubmitting) return;` before the
    // flag is set, and the Create/Save button swapping to a disabled
    // spinner while `_isSubmitting`) mirrors the Expense Form's own,
    // already-reviewed pattern verbatim.

    testWidgets('leaving a dirty form prompts to discard', (tester) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Buy milk');
      await tester.pumpAndSettle();

      final popScope =
          tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).single
              as PopScope;
      expect(popScope.canPop, isFalse);
    });

    testWidgets('a pristine form can be left without a prompt', (tester) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();

      final popScope =
          tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).single
              as PopScope;
      expect(popScope.canPop, isTrue);
    });

    testWidgets(
      'cancelling the discard prompt keeps the form open with input intact',
      (tester) async {
        await tester.pumpWidget(buildFormPushed());
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Open'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, 'Buy milk');
        await tester.pumpAndSettle();

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        expect(find.text('Discard task?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('New task'), findsOneWidget);
        expect(find.text('Buy milk'), findsOneWidget);
      },
    );

    testWidgets('confirming the discard prompt closes the form', (
      tester,
    ) async {
      await tester.pumpWidget(buildFormPushed());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Buy milk');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('New task'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Open'), findsOneWidget);
    });

    testWidgets('assignee field shows a loading state while members load', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildForm(membersOverride: const AsyncValue.loading()),
      );
      await tester.pump();

      expect(find.text('Loading members…'), findsOneWidget);
      expect(find.text('Unassigned'), findsNothing);
    });

    testWidgets(
      'assignee field shows a recoverable error, not a silent Unassigned',
      (tester) async {
        await tester.pumpWidget(
          buildForm(
            membersOverride: AsyncValue.error(
              Exception('boom'),
              StackTrace.empty,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Could not load members.'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
        expect(find.text('Unassigned'), findsNothing);
      },
    );

    testWidgets('long member name does not overflow the assignee field', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildForm(
          membersOverride: const AsyncValue.data([
            TaskMember(
              userId: 'u1',
              displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
              publicId: 'christina#1',
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'recurrence control renders at 2.0x text scale without overflow',
      (tester) async {
        final task = Task(
          id: 't1',
          householdId: 'hh',
          title: 'Water plants',
          createdBy: 'u1',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          dueAt: DateTime.utc(2026, 9, 1, 8),
          recurrenceType: RecurrenceType.weekly,
        );
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(2.0),
            ),
            child: buildForm(existingTask: task),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('description remains reachable with the whole form in view', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm());
      await tester.pumpAndSettle();
      expect(find.text('Description'), findsOneWidget);
      expect(find.byType(TextField).last, findsOneWidget);
    });
  });

  group('TaskFormScreen — edit mode', () {
    final task = Task(
      id: 't1',
      householdId: 'hh',
      title: 'Water plants',
      description: 'Use the blue can',
      assignedTo: 'u2',
      createdBy: 'u1',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      dueAt: DateTime.utc(2026, 9, 1, 8),
      recurrenceType: RecurrenceType.weekly,
    );

    testWidgets('pre-populates existing values with a Save action', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm(existingTask: task));
      await tester.pumpAndSettle();

      expect(find.text('Edit task'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);
      expect(find.text('Water plants'), findsOneWidget);
      expect(find.text('Use the blue can'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.textContaining('Sep 1'), findsOneWidget);
    });

    testWidgets('recurrence control reflects the existing weekly value', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm(existingTask: task));
      await tester.pumpAndSettle();

      final segmented = tester.widget<SegmentedButton<RecurrenceType>>(
        find.byType(SegmentedButton<RecurrenceType>),
      );
      expect(segmented.selected, {RecurrenceType.weekly});
      expect(segmented.onSelectionChanged, isNotNull);
    });

    testWidgets('clearing the due date resets recurrence to none', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm(existingTask: task));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Clear due date'));
      await tester.pumpAndSettle();

      expect(find.text('No due date'), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<RecurrenceType>>(
        find.byType(SegmentedButton<RecurrenceType>),
      );
      expect(segmented.selected, {RecurrenceType.none});
      expect(segmented.onSelectionChanged, isNull);
    });

    testWidgets(
      'an untouched edit form is pristine — initializing controllers from '
      'the existing task does not itself count as a change',
      (tester) async {
        await tester.pumpWidget(buildForm(existingTask: task));
        await tester.pumpAndSettle();

        final popScope =
            tester
                    .widgetList(find.byWidgetPredicate((w) => w is PopScope))
                    .single
                as PopScope;
        expect(popScope.canPop, isTrue);
      },
    );

    testWidgets('editing a loaded value marks the edit form dirty', (
      tester,
    ) async {
      await tester.pumpWidget(buildForm(existingTask: task));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Water all plants');
      await tester.pumpAndSettle();

      final popScope =
          tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).single
              as PopScope;
      expect(popScope.canPop, isFalse);
    });

    testWidgets(
      'edit-mode mutation failure preserves the edited data and shows a '
      'form-level message',
      (tester) async {
        await tester.pumpWidget(buildForm(existingTask: task));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byType(TextField).first,
          'Water all the plants',
        );
        await tester.tap(find.widgetWithText(TextButton, 'Save'));
        await tester.pumpAndSettle();

        expect(find.text('Water all the plants'), findsOneWidget);
        expect(
          find.text('Failed to save task. Please try again.'),
          findsOneWidget,
        );
        final titleField = tester.widget<TextField>(
          find.byType(TextField).first,
        );
        expect(titleField.decoration?.errorText, isNull);
      },
    );
  });
}
