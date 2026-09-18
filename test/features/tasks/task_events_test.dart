import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/household_detail_screen.dart';
import 'package:household_os/features/tasks/domain/task_event.dart';

void main() {
  final occuredAt = DateTime.utc(2026, 8, 25, 12);

  TaskEvent makeEvent(
    String eventType, {
    String? actorDisplayName = 'Anna',
    String taskTitle = 'Clean kitchen',
  }) {
    return TaskEvent(
      id: '1',
      householdId: 'hh',
      eventType: eventType,
      taskTitle: taskTitle,
      occurredAt: occuredAt,
      actorDisplayName: actorDisplayName,
    );
  }

  group('TaskEvent.fromMap', () {
    test('parses a created event with actor profile', () {
      final map = {
        'id': 'evt-1',
        'task_id': 'task-1',
        'household_id': 'hh-1',
        'actor_user_id': 'user-1',
        'actor_profile': {'display_name': 'Anna'},
        'event_type': 'created',
        'task_title': 'Clean kitchen',
        'assigned_to': null,
        'occurred_at': '2026-08-25T12:00:00.000Z',
      };
      final event = TaskEvent.fromMap(map);
      expect(event.id, 'evt-1');
      expect(event.taskId, 'task-1');
      expect(event.householdId, 'hh-1');
      expect(event.actorUserId, 'user-1');
      expect(event.actorDisplayName, 'Anna');
      expect(event.eventType, 'created');
      expect(event.taskTitle, 'Clean kitchen');
      expect(event.assignedTo, isNull);
      expect(event.occurredAt, DateTime.utc(2026, 8, 25, 12));
    });

    test('parses a deleted event with null task_id and null actor', () {
      final map = {
        'id': 'evt-2',
        'task_id': null,
        'household_id': 'hh-1',
        'actor_user_id': null,
        'actor_profile': null,
        'event_type': 'deleted',
        'task_title': 'Old task',
        'assigned_to': null,
        'occurred_at': '2026-08-25T10:00:00.000Z',
      };
      final event = TaskEvent.fromMap(map);
      expect(event.taskId, isNull);
      expect(event.actorUserId, isNull);
      expect(event.actorDisplayName, isNull);
      expect(event.eventType, 'deleted');
    });

    test('parses a completed event with assigned_to', () {
      final map = {
        'id': 'evt-3',
        'task_id': 'task-3',
        'household_id': 'hh-1',
        'actor_user_id': 'user-2',
        'actor_profile': {'display_name': 'Bob'},
        'event_type': 'completed',
        'task_title': 'Buy milk',
        'assigned_to': 'user-2',
        'occurred_at': '2026-08-25T09:00:00.000Z',
      };
      final event = TaskEvent.fromMap(map);
      expect(event.actorDisplayName, 'Bob');
      expect(event.assignedTo, 'user-2');
    });
  });

  group('TaskEvent.displayText', () {
    test('created', () {
      expect(makeEvent('created').displayText, 'Anna created "Clean kitchen"');
    });

    test('updated', () {
      expect(makeEvent('updated').displayText, 'Anna updated "Clean kitchen"');
    });

    test('completed', () {
      expect(
        makeEvent('completed').displayText,
        'Anna completed "Clean kitchen"',
      );
    });

    test('reopened', () {
      expect(
        makeEvent('reopened').displayText,
        'Anna reopened "Clean kitchen"',
      );
    });

    test('deleted', () {
      expect(makeEvent('deleted').displayText, 'Anna deleted "Clean kitchen"');
    });

    test('null actor falls back to Deleted user', () {
      expect(
        makeEvent('completed', actorDisplayName: null).displayText,
        'Deleted user completed "Clean kitchen"',
      );
    });

    test('unknown event type falls back gracefully', () {
      expect(makeEvent('archived').displayText, 'Anna changed "Clean kitchen"');
    });

    test('preserves task title in quotes', () {
      expect(
        makeEvent('created', taskTitle: 'Buy groceries').displayText,
        'Anna created "Buy groceries"',
      );
    });
  });

  group('HouseholdDetailScreen - Recent activity section', () {
    final testHousehold = Household(
      id: 'hh',
      name: 'Test Home',
      createdBy: 'user-1',
      createdAt: DateTime.utc(2026, 8, 25),
    );

    HouseholdEvent makeHouseholdEvent(
      String eventType, {
      String actorDisplayName = 'Anna',
      String title = 'Clean kitchen',
    }) {
      return HouseholdEvent(
        id: 'he-1',
        householdId: 'hh',
        actorDisplayName: actorDisplayName,
        eventType: eventType,
        entityType: 'task',
        titleSnapshot: title,
        occurredAt: occuredAt,
      );
    }

    Widget buildScreen({required List<HouseholdEvent> events}) {
      return ProviderScope(
        overrides: [
          householdByIdProvider(
            'hh',
          ).overrideWith((ref) => Future.value(testHousehold)),
          householdInvitesProvider(
            'hh',
          ).overrideWith((ref) => Future.value([])),
          householdSummaryProvider('hh').overrideWith(
            (ref) => Future.value(
              const HouseholdSummary(
                incompleteTaskCount: 0,
                incompleteShoppingCount: 0,
                expenseCount: 0,
                activeMemberCount: 1,
              ),
            ),
          ),
          householdRecentActivityProvider(
            'hh',
          ).overrideWith((ref) => Future.value(events)),
        ],
        child: MaterialApp(
          theme: appTheme,
          home: const HouseholdDetailScreen(householdId: 'hh'),
        ),
      );
    }

    testWidgets('shows "No activity yet" when list is empty', (tester) async {
      await tester.pumpWidget(buildScreen(events: []));
      await tester.pumpAndSettle();
      expect(find.text('No activity yet'), findsOneWidget);
    });

    testWidgets('renders displayText for each event', (tester) async {
      final events = [
        makeHouseholdEvent(
          'task_created',
          actorDisplayName: 'Anna',
          title: 'Buy milk',
        ),
        makeHouseholdEvent(
          'task_completed',
          actorDisplayName: 'Bob',
          title: 'Buy milk',
        ),
      ];
      await tester.pumpWidget(buildScreen(events: events));
      await tester.pumpAndSettle();
      expect(find.text('Anna created "Buy milk"'), findsOneWidget);
      expect(find.text('Bob completed "Buy milk"'), findsOneWidget);
    });

    testWidgets('renders "Deleted member" for deleted actor', (tester) async {
      final events = [
        makeHouseholdEvent(
          'task_deleted',
          actorDisplayName: 'Deleted member',
          title: 'Old task',
        ),
      ];
      await tester.pumpWidget(buildScreen(events: events));
      await tester.pumpAndSettle();
      expect(find.text('Deleted member deleted "Old task"'), findsOneWidget);
    });
  });
}
