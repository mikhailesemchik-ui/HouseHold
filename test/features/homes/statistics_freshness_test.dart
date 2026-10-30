import 'dart:async' show StreamController;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/domain/household_stats.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/household_detail_screen.dart';
import 'package:household_os/features/homes/presentation/membership_watcher.dart';
import 'package:household_os/features/homes/presentation/statistics_screen.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

// Statistics were a retained FutureProvider fetched once per session, so a task
// completed on another device stayed invisible until the app restarted
// (QA13B: the server said 6 completions, one phone still showed 5). The fix
// reuses two refresh points that already exist: the household_events listener
// of the household screen (which stays mounted underneath the nested
// Statistics route) and the app-resume eviction.

HouseholdEvent _event(String id, String type) => HouseholdEvent.fromMap({
  'id': id,
  'household_id': 'hh',
  'actor_user_id': 'u',
  'actor_display_name': 'Alice',
  'event_type': type,
  'entity_type': 'task',
  'entity_id': 'e',
  'title_snapshot': 'Clean kitchen',
  'amount_cents': null,
  'currency': null,
  'occurred_at': '2026-08-27T10:00:00.000Z',
});

HouseholdStats _stats(HouseholdStatsPeriod period, int completed) =>
    HouseholdStats(
      period: period,
      totalCompletedTasks: completed,
      memberStats: const [],
      taskDistributions: const [],
      fairnessInsight: '',
    );

HouseholdStatsRequest _req(String id, [HouseholdStatsPeriod? p]) =>
    HouseholdStatsRequest(
      householdId: id,
      period: p ?? HouseholdStatsPeriod.last30Days,
    );

void main() {
  group('remote events refresh Statistics while the household is open', () {
    late StreamController<List<HouseholdEvent>> events;
    late Map<String, int> fetches; // 'household/period' -> fetch count
    late Map<String, int> completed; // what the "server" says
    var rotationFetches = 0;

    setUp(() {
      events = StreamController<List<HouseholdEvent>>();
      addTearDown(events.close);
      fetches = {};
      completed = {'hh': 5, 'other': 7};
      rotationFetches = 0;
    });

    Widget app({bool failSecondFetch = false}) {
      return ProviderScope(
        overrides: [
          householdByIdProvider('hh').overrideWith(
            (ref) async => Household(
              id: 'hh',
              name: 'Test Home',
              createdBy: 'u',
              createdAt: DateTime.utc(2026, 8, 1),
            ),
          ),
          householdInvitesProvider('hh').overrideWith((ref) async => const []),
          householdRecentActivityProvider(
            'hh',
          ).overrideWith((ref) async => const []),
          householdEventsStreamProvider(
            'hh',
          ).overrideWith((ref) => events.stream),
          householdSummaryProvider('hh').overrideWith(
            (ref) async => const HouseholdSummary(
              incompleteTaskCount: 0,
              incompleteShoppingCount: 0,
              expenseCount: 0,
              activeMemberCount: 1,
            ),
          ),
          householdMembersProvider('hh').overrideWith((ref) async => const []),
          taskMembersProvider(
            'hh',
          ).overrideWith((ref) async => const <TaskMember>[]),
          taskRotationSuggestionsProvider('hh').overrideWith((ref) async {
            rotationFetches++;
            return const [];
          }),
          for (final id in ['hh', 'other'])
            for (final period in HouseholdStatsPeriod.values)
              householdStatsProvider(_req(id, period)).overrideWith((
                ref,
              ) async {
                final key = '$id/${period.name}';
                fetches[key] = (fetches[key] ?? 0) + 1;
                if (failSecondFetch && id == 'hh' && fetches[key]! >= 2) {
                  throw StateError('offline');
                }
                return _stats(period, completed[id]!);
              }),
        ],
        child: MaterialApp(
          home: Column(
            children: [
              const Expanded(
                child: HouseholdDetailScreen(
                  householdId: 'hh',
                  currentUserIdOverride: 'u',
                ),
              ),
              // Stands in for the Statistics screen that sits above the
              // household screen in the navigator.
              Consumer(
                builder: (context, ref, _) {
                  final mine = ref.watch(householdStatsProvider(_req('hh')));
                  final other = ref.watch(
                    householdStatsProvider(_req('other')),
                  );
                  return Text(
                    'hh=${mine.hasError ? 'error' : mine.value?.totalCompletedTasks} '
                    'other=${other.value?.totalCompletedTasks}',
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    Future<void> deliver(WidgetTester tester, List<HouseholdEvent> list) async {
      events.add(list);
      await tester.pumpAndSettle();
    }

    testWidgets('S1 initial snapshot, and the first events emission is no '
        'refresh', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('hh=5 other=7'), findsOneWidget);

      await deliver(tester, [_event('1', 'task_created')]);
      expect(fetches['hh/last30Days'], 1);
    });

    testWidgets('S2 a remote task completion refreshes the open Statistics '
        'and every period', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);

      completed['hh'] = 6; // completed on the other phone
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('2', 'task_completed'),
      ]);

      expect(find.text('hh=6 other=7'), findsOneWidget);
      expect(fetches['hh/last30Days'], 2);
      expect(rotationFetches, 0, reason: 'only watched providers refetch');
    });

    testWidgets('S3 a recurring occurrence completion arrives the same way '
        '(it is a task_completed event)', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);

      completed['hh'] = 6;
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('3', 'task_completed'),
      ]);
      expect(find.text('hh=6 other=7'), findsOneWidget);
    });

    testWidgets('S6 another household is left alone', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('2', 'task_completed'),
      ]);

      expect(fetches['other/last30Days'], 1);
    });

    testWidgets('shopping and expense events cannot change Statistics', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('4', 'shopping_item_added'),
        _event('5', 'expense_created'),
      ]);

      expect(fetches['hh/last30Days'], 1);
    });

    testWidgets('membership events refresh it too (active-member labels)', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('6', 'member_left'),
      ]);

      expect(fetches['hh/last30Days'], 2);
    });

    testWidgets('S7 the same events delivered again do not refetch', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);
      final list = [_event('1', 'task_created'), _event('2', 'task_completed')];
      await deliver(tester, list);
      await deliver(tester, list);
      await deliver(tester, list);

      expect(fetches['hh/last30Days'], 2, reason: 'one refetch per new event');
    });

    testWidgets('S8 a failed refresh shows an error, never invented numbers', (
      tester,
    ) async {
      await tester.pumpWidget(app(failSecondFetch: true));
      await tester.pumpAndSettle();
      await deliver(tester, [_event('1', 'task_created')]);
      await deliver(tester, [
        _event('1', 'task_created'),
        _event('2', 'task_completed'),
      ]);

      expect(find.text('hh=error other=7'), findsOneWidget);
    });
  });

  group('S5 app resume', () {
    Widget app(void Function(String key) onFetch) {
      final router = GoRouter(
        initialLocation: '/homes',
        routes: [
          ShellRoute(
            builder: (_, _, child) => MembershipWatcher(child: child),
            routes: [
              GoRoute(
                path: '/homes',
                builder: (_, _) => Consumer(
                  builder: (context, ref, _) {
                    ref.watch(homesProvider);
                    final s = ref.watch(householdStatsProvider(_req('hh')));
                    return Text('count ${s.value?.totalCompletedTasks}');
                  },
                ),
              ),
            ],
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          homesProvider.overrideWith(() => _OneHome()),
          activeHouseholdIdsProvider.overrideWith(
            (ref) => Stream.value({'hh'}),
          ),
          householdSummaryProvider('hh').overrideWith(
            (ref) async => const HouseholdSummary(
              incompleteTaskCount: 0,
              incompleteShoppingCount: 0,
              expenseCount: 0,
              activeMemberCount: 1,
            ),
          ),
          for (final period in HouseholdStatsPeriod.values)
            householdStatsProvider(_req('hh', period)).overrideWith((
              ref,
            ) async {
              onFetch(period.name);
              return _stats(period, _serverCount);
            }),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    testWidgets('resuming fetches an authoritative snapshot, once per resume', (
      tester,
    ) async {
      var fetches = 0;
      _serverCount = 5;
      await tester.pumpWidget(app((_) => fetches++));
      await tester.pumpAndSettle();
      expect(find.text('count 5'), findsOneWidget);
      expect(fetches, 1);

      _serverCount = 6; // completed elsewhere while the app was away
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('count 6'), findsOneWidget);
      expect(fetches, 2);
    });
  });

  testWidgets('the real Statistics screen keeps its numbers while refreshing '
      'and shows the new ones', (tester) async {
    var server = 5;
    final container = ProviderContainer(
      overrides: [
        householdStatsProvider(_req('hh')).overrideWith(
          (ref) async => _stats(HouseholdStatsPeriod.last30Days, server),
        ),
        taskRotationSuggestionsProvider('hh').overrideWith((ref) async => []),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: StatisticsScreen(householdId: 'hh')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('5'), findsOneWidget);

    server = 6;
    container.invalidate(householdStatsProvider(_req('hh')));
    await tester.pump();
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'the old numbers stay up while the refresh runs',
    );
    await tester.pumpAndSettle();
    expect(find.text('6'), findsOneWidget);
  });

  // QA17: a 401 right after the host woke up left "Could not load rotation
  // suggestions" on screen while the numbers above it were fine. Automatic
  // provider retries are off (noProviderRetry), so the card recovers through
  // Retry or the F16 invalidation, and never loops on a persistent failure.
  group('rotation suggestions error recovery', () {
    const failedText = 'Could not load rotation suggestions.';
    late ProviderContainer container;
    late int calls;

    Future<void> pumpScreen(
      WidgetTester tester,
      List<TaskRotationSuggestion> Function(int call) load,
    ) async {
      calls = 0;
      container = ProviderContainer(
        overrides: [
          householdStatsProvider(_req('hh')).overrideWith(
            (ref) async => _stats(HouseholdStatsPeriod.last30Days, 5),
          ),
          taskRotationSuggestionsProvider('hh').overrideWith((ref) async {
            calls++;
            return load(calls);
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: StatisticsScreen(householdId: 'hh')),
        ),
      );
      await tester.pumpAndSettle();
    }

    const suggestion = TaskRotationSuggestion(
      taskId: 'task-1',
      taskTitle: 'Clean kitchen',
      dominantMemberId: 'u1',
      dominantMemberName: 'Anna',
      suggestedMemberId: 'u2',
      suggestedMemberName: 'Mihails',
      dominantCompletionCount: 7,
      totalCompletionCount: 8,
      dominantShare: 87.5,
    );

    testWidgets('Retry after a transient failure replaces the error with data, '
        'and the statistics stay correct meanwhile', (tester) async {
      await pumpScreen(
        tester,
        (call) => call == 1 ? throw StateError('401') : [suggestion],
      );
      expect(find.text(failedText), findsOneWidget);
      expect(find.text('5'), findsOneWidget, reason: 'numbers unaffected');

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(find.text(failedText), findsNothing);
      expect(find.text('Rotation suggestions'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('a refresh from the F16 invalidation clears the error, and an '
        'empty result is a legitimate empty state', (tester) async {
      await pumpScreen(
        tester,
        (call) => call == 1 ? throw StateError('401') : const [],
      );
      expect(find.text(failedText), findsOneWidget);

      container.invalidate(taskRotationSuggestionsProvider('hh'));
      await tester.pumpAndSettle();

      expect(find.text(failedText), findsNothing);
      expect(find.text('Rotation suggestions'), findsNothing);
      expect(calls, 2);
    });

    testWidgets('a persistent failure stays visible and fetches once per '
        'Retry, never in a loop', (tester) async {
      await pumpScreen(tester, (_) => throw StateError('403'));
      expect(calls, 1);

      await tester.pump(const Duration(seconds: 30));
      expect(calls, 1, reason: 'no automatic retry');

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));

      expect(find.text(failedText), findsOneWidget);
      expect(calls, 2);
    });
  });
}

int _serverCount = 5;

class _OneHome extends HomesNotifier {
  @override
  Future<List<Household>> build() async => [
    Household(
      id: 'hh',
      name: 'QA hh',
      createdBy: 'u',
      createdAt: DateTime.utc(2026, 9, 1),
    ),
  ];
}
