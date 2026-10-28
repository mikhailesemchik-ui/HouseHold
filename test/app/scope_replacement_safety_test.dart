import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/reminder_settings.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/financial_submission.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/today/domain/today_entry.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What happens to work that user A started when the signed-in user changes
/// and the user-scoped root disposes A's providers, using the REAL notifiers
/// and submission code with only the network replaced.

Household _home(String id) => Household(
  id: id,
  name: 'Home $id',
  createdBy: 'user-a',
  createdAt: DateTime(2026),
);

class _FakeHouseholds implements HouseholdRepository {
  _FakeHouseholds({this.initial = const []});

  final List<Household> initial;
  Completer<void>? gate;
  final calls = <String>[];

  @override
  Future<List<Household>> fetchActiveHouseholds() async => initial;

  @override
  Future<Household> createHousehold(String name) async {
    calls.add('create');
    await gate?.future;
    return _home('created');
  }

  @override
  Future<Household> joinHousehold(String inviteCode) async {
    calls.add('join');
    await gate?.future;
    return _home('joined');
  }

  @override
  Future<void> leaveHousehold(String householdId) async {
    calls.add('leave');
    await gate?.future;
  }

  @override
  Future<void> deleteHousehold(String householdId) async {
    calls.add('delete');
    await gate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _scope(_FakeHouseholds repo) => ProviderContainer(
  overrides: [householdRepositoryProvider.overrideWithValue(repo)],
);

void main() {
  group('household mutations that finish after the scope was replaced', () {
    for (final name in ['create', 'join', 'leave', 'delete']) {
      test('$name: completes quietly, never throws into the caller, and does '
          'not touch the next user\'s list', () async {
        final repoA = _FakeHouseholds(initial: [_home('a1')])
          ..gate = Completer<void>();
        final scopeA = _scope(repoA);
        await scopeA.read(homesProvider.future);
        final notifier = scopeA.read(homesProvider.notifier);
        final inFlight = switch (name) {
          'create' => notifier.createHousehold('X'),
          'join' => notifier.joinHousehold('CODE'),
          'leave' => notifier.leaveHousehold('a1'),
          _ => notifier.deleteHousehold('a1'),
        };

        // User B: a fresh scope with their own (empty) data.
        scopeA.dispose();
        final scopeB = _scope(_FakeHouseholds());
        addTearDown(scopeB.dispose);
        expect(await scopeB.read(homesProvider.future), isEmpty);

        repoA.gate!.complete();
        await inFlight; // the old request finishes; no UnmountedRefException
        expect(await scopeB.read(homesProvider.future), isEmpty);
        expect(repoA.calls, [name], reason: 'it ran once, as the old user');
      });
    }

    test('within one scope nothing changed: the list still updates', () async {
      final repo = _FakeHouseholds(initial: [_home('a1')]);
      final scope = _scope(repo);
      addTearDown(scope.dispose);
      await scope.read(homesProvider.future);
      await scope.read(homesProvider.notifier).createHousehold('X');
      expect(scope.read(homesProvider).value!.map((h) => h.id), [
        'a1',
        'created',
      ]);
    });
  });

  group('a financial submission and the identity that opened it', () {
    const request = 'expense';

    Future<({List<String> sent, ProviderContainer container})> pump(
      WidgetTester tester, {
      required String openedAs,
      required String? liveAs,
      required void Function(bool? accepted) onResult,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final sent = <String>[];
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue(openedAs),
            liveAuthUserIdProvider.overrideWithValue(() => liveAs),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return TextButton(
                    onPressed: () async {
                      final accepted = await FinancialSubmission.run(
                        context: context,
                        ref: ref,
                        kind: request,
                        householdId: 'hh-1',
                        payloadParts: const ['hh-1', 'Dinner', '3000'],
                        send: (requestId) async => sent.add(requestId),
                        failureMessage: 'Failed to add expense.',
                      );
                      onResult(accepted);
                    },
                    child: const Text('submit'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      return (sent: sent, container: container);
    }

    List<PendingFinancialOperation> pending(
      SharedPreferences prefs,
      String user,
    ) => FinancialRequestStore(
      prefs,
    ).pending(userId: user, householdId: 'hh-1', kind: request);

    testWidgets('same user: sent once and the saved id is released', (
      tester,
    ) async {
      bool? result;
      final run = await pump(
        tester,
        openedAs: 'user-a',
        liveAs: 'user-a',
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('submit'));
      await tester.pumpAndSettle();
      expect(run.sent, hasLength(1));
      expect(result, isTrue);
      expect(pending(await SharedPreferences.getInstance(), 'user-a'), isEmpty);
    });

    testWidgets('identity unknown (cannot be read): behaves as before', (
      tester,
    ) async {
      final run = await pump(
        tester,
        openedAs: 'user-a',
        liveAs: null,
        onResult: (_) {},
      );
      await tester.tap(find.text('submit'));
      await tester.pumpAndSettle();
      expect(run.sent, hasLength(1));
    });

    testWidgets('the user changed before sending: nothing is sent, A\'s saved '
        'request id stays under A, B gets none', (tester) async {
      bool? result;
      final run = await pump(
        tester,
        openedAs: 'user-a',
        liveAs: 'user-b',
        onResult: (r) => result = r,
      );
      await tester.tap(find.text('submit'));
      await tester.pumpAndSettle();

      expect(run.sent, isEmpty, reason: 'no request under the new session');
      expect(result, isFalse);
      expect(find.text('Failed to add expense.'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(pending(prefs, 'user-a'), hasLength(1));
      expect(pending(prefs, 'user-b'), isEmpty);
    });
  });

  group('reminders and the scope replacement', () {
    test('a reconciliation that finishes after the scope was replaced '
        'schedules nothing for the previous user', () async {
      SharedPreferences.setMockInitialValues({});
      await ReminderSettings.setEnabled(true);
      final scope = ProviderContainer(
        overrides: [todayProvider.overrideWith(_IdleToday.new)],
      );
      await scope.read(todayProvider.future);
      final notifier = scope.read(todayProvider.notifier);
      final pending = notifier.reconcileReminders();
      scope.dispose();
      // Without the guard this reaches the real notification plugin, which
      // does not exist in tests and would throw here.
      await pending;
    });
  });
}

class _IdleToday extends TodayNotifier {
  @override
  Future<Map<String, List<TodayEntry>>> build() async => {};
}
