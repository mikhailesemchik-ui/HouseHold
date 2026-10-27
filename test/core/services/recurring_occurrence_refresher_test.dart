import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/core/services/recurring_occurrence_refresher.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/membership_watcher.dart';
import 'package:household_os/features/tasks/domain/task.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/domain/task_occurrence.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 26, 9);
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('RecurringOccurrenceRefresher', () {
    late _Clock clock;
    late String? user;
    late int calls;
    late Future<void> Function() onRun;

    RecurringOccurrenceRefresher build() => RecurringOccurrenceRefresher(
      currentUserId: () => user,
      run: () {
        calls++;
        return onRun();
      },
      clock: () => clock.now,
    );

    setUp(() {
      clock = _Clock();
      user = 'u1';
      calls = 0;
      onRun = () async {};
    });

    test('overlapping calls share one request', () async {
      final gate = Completer<void>();
      onRun = () => gate.future;
      final refresher = build();
      final first = refresher.refresh();
      final second = refresher.refresh();
      gate.complete();
      await Future.wait([first, second]);
      expect(calls, 1);
    });

    test(
      'repeated resume within the interval is throttled, then runs again',
      () async {
        final refresher = build();
        await refresher.refresh();
        clock.advance(const Duration(minutes: 5));
        await refresher.refresh();
        expect(calls, 1);

        clock.advance(const Duration(minutes: 11));
        await refresher.refresh();
        expect(calls, 2);
      },
    );

    test(
      'a different signed-in user is not throttled by the previous one',
      () async {
        final refresher = build();
        await refresher.refresh();
        user = 'u2';
        await refresher.refresh();
        expect(calls, 2);
      },
    );

    test('signed-out refresh does nothing', () async {
      user = null;
      final refresher = build();
      await refresher.refresh();
      expect(calls, 0);
    });

    test('failure is swallowed and the next trigger retries', () async {
      onRun = () async => throw StateError('offline');
      final refresher = build();
      await refresher.refresh();
      expect(calls, 1);

      onRun = () async {};
      await refresher.refresh();
      expect(calls, 2);
      await refresher.refresh();
      expect(calls, 2);
    });

    test('a failing lookup of the signed-in user is swallowed', () async {
      final refresher = RecurringOccurrenceRefresher(
        currentUserId: () => throw StateError('not initialized'),
        run: () async => calls++,
      );
      await refresher.refresh();
      expect(calls, 0);
    });
  });

  group('RecurringOccurrenceRefresher per-user state and clock', () {
    late _Clock clock;
    late String? user;
    late List<Completer<void>> runs;
    late List<String?> runUsers;

    RecurringOccurrenceRefresher build() => RecurringOccurrenceRefresher(
      currentUserId: () => user,
      run: () {
        runUsers.add(user);
        final gate = Completer<void>();
        runs.add(gate);
        return gate.future;
      },
      clock: () => clock.now,
    );

    setUp(() {
      clock = _Clock();
      user = 'a';
      runs = [];
      runUsers = [];
    });

    test(
      'repeated resumes during an in-flight request make one call',
      () async {
        final refresher = build();
        final calls = [
          refresher.refresh(),
          refresher.refresh(),
          refresher.refresh(),
        ];
        expect(runs, hasLength(1));
        runs.single.complete();
        await Future.wait(calls);
        expect(runs, hasLength(1));
      },
    );

    test(
      'B does not join the in-flight request of A and is not throttled by it',
      () async {
        final refresher = build();
        final a = refresher.refresh();

        user = null; // A signs out while the request is still in flight
        await refresher.refresh();
        expect(runs, hasLength(1));

        user = 'b';
        final b = refresher.refresh();
        expect(runs, hasLength(2));
        expect(runUsers, ['a', 'b']);

        runs[0].complete(); // A finishes after B started
        await a;
        runs[1].completeError(StateError('offline')); // B fails
        await b;

        // A's success did not count for B: B retries at once.
        final retry = refresher.refresh();
        expect(runs, hasLength(3));
        expect(runUsers.last, 'b');
        runs.last.complete();
        await retry;
      },
    );

    test(
      'a late A completion does not overwrite B state; each user is throttled alone',
      () async {
        final refresher = build();
        final a = refresher.refresh();
        user = 'b';
        final b = refresher.refresh();
        runs[1].complete();
        await b;
        runs[0].complete();
        await a;

        await refresher.refresh(); // B within window
        expect(runs, hasLength(2));
        user = 'a';
        await refresher.refresh(); // A within window too
        expect(runs, hasLength(2));
      },
    );

    test(
      'same-user failure clears in-flight state so the next call retries',
      () async {
        final refresher = build();
        final first = refresher.refresh();
        runs.single.completeError(StateError('boom'));
        await first;
        final second = refresher.refresh();
        expect(runs, hasLength(2));
        runs.last.complete();
        await second;
      },
    );

    test('realistic network and Supabase errors never escape', () async {
      for (final error in <Object>[
        const SocketException('Failed host lookup'),
        TimeoutException('rpc timed out'),
        const PostgrestException(message: 'JWT expired', code: 'PGRST301'),
        const PostgrestException(message: 'upstream', code: '503'),
      ]) {
        final refresher = build();
        final call = refresher.refresh();
        runs.last.completeError(error);
        await expectLater(call, completes);
      }
    });

    test(
      'throttle holds inside 15 minutes and expires at 15 minutes',
      () async {
        final refresher = build();
        final first = refresher.refresh();
        runs.single.complete();
        await first;

        clock.advance(const Duration(minutes: 14, seconds: 59));
        await refresher.refresh();
        expect(runs, hasLength(1));

        clock.advance(const Duration(seconds: 1));
        final again = refresher.refresh();
        expect(runs, hasLength(2));
        runs.last.complete();
        await again;
      },
    );

    test(
      'a backwards clock jump past the last success refreshes immediately',
      () async {
        final refresher = build();
        final first = refresher.refresh();
        runs.single.complete();
        await first;

        clock.advance(const Duration(minutes: -60));
        final second = refresher.refresh();
        expect(runs, hasLength(2));
        runs.last.complete();
        await second;

        // The success re-anchors the throttle at the adjusted time.
        clock.advance(const Duration(minutes: 5));
        await refresher.refresh();
        expect(runs, hasLength(2));
      },
    );

    test(
      'a small backwards jump delays refresh by less than one interval',
      () async {
        final refresher = build();
        final first = refresher.refresh();
        runs.single.complete();
        await first;

        clock.advance(const Duration(minutes: 10));
        clock.advance(const Duration(minutes: -3)); // 7 minutes since success
        await refresher.refresh();
        expect(runs, hasLength(1));

        clock.advance(const Duration(minutes: 8));
        final next = refresher.refresh();
        expect(runs, hasLength(2));
        runs.last.complete();
        await next;
      },
    );

    test(
      'signed-out refresh starts nothing and leaves state untouched',
      () async {
        user = null;
        final refresher = build();
        await refresher.refresh();
        await refresher.refresh();
        expect(runs, isEmpty);

        user = 'a';
        final call = refresher.refresh();
        expect(runs, hasLength(1));
        runs.single.complete();
        await call;
      },
    );
  });

  group('refresh triggers', () {
    testWidgets('opening Tasks requests a refresh', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recurringOccurrenceRefresherProvider.overrideWithValue(
              RecurringOccurrenceRefresher(
                currentUserId: () => 'u1',
                run: () async => calls++,
              ),
            ),
            tasksStreamProvider(
              'hh',
            ).overrideWith((ref) => Stream.value(const <Task>[])),
            taskMembersProvider(
              'hh',
            ).overrideWith((ref) => Future.value(<TaskMember>[])),
            occurrencesStreamProvider(
              'hh',
            ).overrideWith((ref) => Stream.value(const <TaskOccurrence>[])),
          ],
          child: const MaterialApp(home: TasksScreen(householdId: 'hh')),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets(
      'app resume refreshes once per throttle window, any household',
      (tester) async {
        var calls = 0;
        final homes = [
          Household(
            id: 'a',
            name: 'A',
            createdBy: 'u',
            createdAt: DateTime.utc(2026, 9, 1),
          ),
          Household(
            id: 'b',
            name: 'B',
            createdBy: 'u',
            createdAt: DateTime.utc(2026, 9, 1),
          ),
        ];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recurringOccurrenceRefresherProvider.overrideWithValue(
                RecurringOccurrenceRefresher(
                  currentUserId: () => 'u1',
                  run: () async => calls++,
                ),
              ),
              homesProvider.overrideWith(() => _FakeHomes(homes)),
              activeHouseholdIdsProvider.overrideWith(
                (ref) => Stream.value({'a', 'b'}),
              ),
            ],
            child: MaterialApp.router(
              routerConfig: GoRouter(
                routes: [
                  ShellRoute(
                    builder: (_, _, child) => MembershipWatcher(child: child),
                    routes: [
                      GoRoute(
                        path: '/',
                        builder: (_, _) => Consumer(
                          builder: (context, ref, _) {
                            ref.watch(homesProvider);
                            return const Text('home');
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, 0);

        for (var i = 0; i < 3; i++) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
        }
        expect(calls, 1);
      },
    );
  });
}

class _FakeHomes extends HomesNotifier {
  _FakeHomes(this.homes);
  final List<Household> homes;
  @override
  Future<List<Household>> build() async => homes;
}
