import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
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

        await tester.tap(find.byType(AppBackButton));
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

      await tester.tap(find.byType(AppBackButton));
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
        // The inline Retry must stay a 48dp touch target (shrinkWrap only drops the
        // extra padding; the theme's minimumSize provides the size).
        final retrySize = tester.getSize(
          find.widgetWithText(TextButton, 'Retry'),
        );
        expect(retrySize.height, greaterThanOrEqualTo(48));
        expect(retrySize.width, greaterThanOrEqualTo(48));
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

    group('assignee who is no longer an active member', () {
      // No Supabase client exists in tests, so a submission that really
      // starts ends in the "Failed to save" message; its absence proves that
      // nothing was submitted.
      const failed = 'Failed to save task. Please try again.';
      const clearTitle = 'Clear the assignee?';

      Task taskFor(String? assignee) => Task(
        id: 't1',
        householdId: 'hh',
        title: 'Water plants',
        assignedTo: assignee,
        completedAt: DateTime.utc(2026, 8, 1),
        createdBy: 'u1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      Future<void> editTitleAndSave(WidgetTester tester) async {
        await tester.enterText(find.byType(TextField).first, 'Water all');
        await tester.tap(find.widgetWithText(TextButton, 'Save'));
        await tester.pumpAndSettle();
      }

      testWidgets('saving asks first and explains what is cleared', (
        tester,
      ) async {
        await tester.pumpWidget(buildForm(existingTask: taskFor('gone')));
        await tester.pumpAndSettle();
        await editTitleAndSave(tester);

        expect(find.text(clearTitle), findsOneWidget);
        expect(find.textContaining('no longer an active'), findsOneWidget);
        expect(find.textContaining('history is not changed'), findsOneWidget);
        expect(find.text(failed), findsNothing);
      });

      testWidgets('cancelling submits nothing and keeps the edits', (
        tester,
      ) async {
        await tester.pumpWidget(buildForm(existingTask: taskFor('gone')));
        await tester.pumpAndSettle();
        await editTitleAndSave(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(find.text(clearTitle), findsNothing);
        expect(find.text(failed), findsNothing);
        expect(find.text('Water all'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);
      });

      testWidgets('confirming goes on to save', (tester) async {
        await tester.pumpWidget(buildForm(existingTask: taskFor('gone')));
        await tester.pumpAndSettle();
        await editTitleAndSave(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Clear and save'));
        await tester.pumpAndSettle();

        expect(find.text(failed), findsOneWidget);
        expect(find.text('Water all'), findsOneWidget);
      });

      testWidgets('an active or missing assignee is never asked about', (
        tester,
      ) async {
        for (final assignee in ['u2', null]) {
          await tester.pumpWidget(buildForm(existingTask: taskFor(assignee)));
          await tester.pumpAndSettle();
          await editTitleAndSave(tester);

          expect(find.text(clearTitle), findsNothing);
          expect(find.text(failed), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('the former assignee is not offered as a choice', (
        tester,
      ) async {
        await tester.pumpWidget(buildForm(existingTask: taskFor('gone')));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<String?>));
        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsWidgets);
        expect(find.text('Bob'), findsWidgets);
        expect(find.text('Unassigned'), findsWidgets);
        expect(find.text('Former member'), findsNothing);
      });

      testWidgets('an unavailable member list blocks saving, edits kept', (
        tester,
      ) async {
        for (final state in <AsyncValue<List<TaskMember>>>[
          const AsyncLoading(),
          AsyncError(StateError('down'), StackTrace.empty),
        ]) {
          await tester.pumpWidget(
            buildForm(existingTask: taskFor('gone'), membersOverride: state),
          );
          await tester.pump();
          await tester.pump();
          await tester.enterText(find.byType(TextField).first, 'Water all');
          await tester.tap(find.widgetWithText(TextButton, 'Save'));
          await tester.pump();

          expect(find.textContaining("Couldn't check household"), findsOne);
          expect(find.text(clearTitle), findsNothing);
          expect(find.text(failed), findsNothing);
          expect(find.text('Water all'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        }
      });
    });
  });

  // The server drops recurring slots earlier than the save instant, and the
  // form's default time is the current minute, so a just-passed start used to
  // lose the first occurrence. Every clock here is injected; nothing reads the
  // real time.
  group('TaskFormScreen — first occurrence of a new recurring task', () {
    late DateTime clock;
    late List<({DateTime? dueAt, RecurrenceType recurrence})> created;
    Completer<void>? holdCreate;

    // Pushed on a real navigator, so a successful save can pop the form.
    Widget buildCreate({Task? existingTask}) {
      return ProviderScope(
        overrides: [
          taskMembersProvider('hh').overrideWith((ref) async => members),
        ],
        child: MaterialApp(
          theme: appTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TaskFormScreen(
                      householdId: 'hh',
                      existingTask: existingTask,
                      nowOverride: () => clock,
                      createTaskOverride: (dueAt, recurrence) async {
                        created.add((dueAt: dueAt, recurrence: recurrence));
                        await holdCreate?.future;
                      },
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
    }

    setUp(() {
      created = [];
      holdCreate = null;
      clock = DateTime(2026, 10, 29, 17, 46, 10);
    });

    Future<void> openAndPickDefaultTime(
      WidgetTester tester, {
      required String repeat,
    }) async {
      await tester.pumpWidget(buildCreate());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Water plants');
      await tester.tap(find.text('Set due date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK')); // date: today, from the injected clock
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK')); // time: the current minute, 17:46
      await tester.pumpAndSettle();
      expect(find.text('Oct 29 · 17:46'), findsOneWidget);
      await tester.tap(find.text(repeat));
      await tester.pumpAndSettle();
    }

    const adjustedNote =
        'Start moved to Oct 29 · 17:49 so the first occurrence is not '
        'skipped. Tap Create again to confirm.';
    const skippedNote =
        'That time has already passed, so this occurrence will be skipped and '
        'the first one will follow the repeat schedule.';

    testWidgets('a just-passed start is moved, shown, and only saved after a '
        'second tap', (tester) async {
      await openAndPickDefaultTime(tester, repeat: 'Weekly');
      clock = DateTime(2026, 10, 29, 17, 47, 30); // form-filling took 80 s

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created, isEmpty, reason: 'nothing is sent behind the back');
      expect(find.text(adjustedNote), findsOneWidget);
      expect(find.text('Oct 29 · 17:49'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created, hasLength(1));
      expect(created.single.recurrence, RecurrenceType.weekly);
      expect(created.single.dueAt!.isUtc, isTrue);
      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 49).toUtc());
    });

    testWidgets('daily is treated the same way', (tester) async {
      await openAndPickDefaultTime(tester, repeat: 'Daily');
      clock = DateTime(2026, 10, 29, 17, 47, 30);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created.single.recurrence, RecurrenceType.daily);
      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 49).toUtc());
    });

    testWidgets('a confirmed save is sent once, even while it is in flight', (
      tester,
    ) async {
      holdCreate = Completer<void>();
      await openAndPickDefaultTime(tester, repeat: 'Weekly');
      clock = DateTime(2026, 10, 29, 17, 47, 30);
      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pump();

      expect(find.widgetWithText(TextButton, 'Create'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(created, hasLength(1));
      holdCreate!.complete();
      await tester.pumpAndSettle();
      expect(created, hasLength(1));
    });

    testWidgets('an older same-day start is kept, flagged before saving, and '
        'not moved', (tester) async {
      await openAndPickDefaultTime(tester, repeat: 'Weekly');
      clock = DateTime(2026, 10, 29, 20, 5);
      await tester.tap(find.text('Daily')); // any change rebuilds the form
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weekly'));
      await tester.pumpAndSettle();

      expect(find.text(skippedNote), findsOneWidget);
      expect(find.text('Oct 29 · 17:46'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created, hasLength(1));
      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 46).toUtc());
    });

    testWidgets('Create shows the skip warning first when time passed without '
        'the form rebuilding', (tester) async {
      await openAndPickDefaultTime(tester, repeat: 'Weekly');
      clock = DateTime(2026, 10, 29, 20, 5); // idle for hours, no rebuild
      expect(find.text(skippedNote), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created, isEmpty, reason: 'warned before saving');
      expect(find.text(skippedNote), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created, hasLength(1));
      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 46).toUtc());
    });

    testWidgets('a start that is still ahead gets no note and no change', (
      tester,
    ) async {
      await openAndPickDefaultTime(tester, repeat: 'Weekly');
      clock = DateTime(2026, 10, 29, 17, 40); // six minutes before the start
      await tester.tap(find.text('Daily'));
      await tester.pumpAndSettle();

      expect(find.text(adjustedNote), findsNothing);
      expect(find.text(skippedNote), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 46).toUtc());
      expect(created.single.recurrence, RecurrenceType.daily);
    });

    testWidgets('a one-off task keeps its past time untouched', (tester) async {
      await openAndPickDefaultTime(tester, repeat: 'None');
      clock = DateTime(2026, 10, 29, 17, 47, 30);

      await tester.tap(find.widgetWithText(TextButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text(adjustedNote), findsNothing);
      expect(created.single.recurrence, RecurrenceType.none);
      expect(created.single.dueAt, DateTime(2026, 10, 29, 17, 46).toUtc());
    });

    testWidgets('editing an existing recurring task shows no first-occurrence '
        'note', (tester) async {
      final existing = Task(
        id: 't1',
        householdId: 'hh',
        title: 'Water plants',
        createdBy: 'u1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        dueAt: DateTime(2026, 10, 29, 17, 46).toUtc(),
        recurrenceType: RecurrenceType.weekly,
      );
      clock = DateTime(2026, 10, 29, 22, 5);
      await tester.pumpWidget(buildCreate(existingTask: existing));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Oct 29 · 17:46'), findsOneWidget);
      expect(find.text(skippedNote), findsNothing);
      expect(find.text(adjustedNote), findsNothing);
    });
  });
}
