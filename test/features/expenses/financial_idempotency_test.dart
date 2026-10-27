import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/expenses/data/financial_submit_outcome.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/financial_request.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Scripted repository: each call pops the next behaviour (an error to throw,
/// a Completer to wait for, or null for success) and records the request id.
class _FakeRepository implements ExpenseRepository {
  _FakeRepository(this.script);

  final List<Object?> script;
  final List<String?> settlementIds = [];
  final List<String?> expenseIds = [];
  final List<int> settlementAmounts = [];

  Future<void> _next() async {
    final step = script.isEmpty ? null : script.removeAt(0);
    if (step is Completer<void>) await step.future;
    if (step is Exception) throw step;
  }

  @override
  Future<void> createSettlement({
    required String householdId,
    required String fromUserId,
    required String toUserId,
    required int amountCents,
    required String currency,
    String? note,
    String? requestId,
  }) async {
    settlementIds.add(requestId);
    settlementAmounts.add(amountCents);
    await _next();
  }

  @override
  Future<void> createEqualSplitExpense({
    required String householdId,
    required String title,
    required int amountCents,
    required String currency,
    required String paidBy,
    required List<String> participantIds,
    String? requestId,
  }) async {
    expenseIds.add(requestId);
    await _next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A store whose durable write fails: nothing may be sent when it does.
class _FailingStore extends FinancialRequestStore {
  _FailingStore(super.prefs);

  @override
  Future<PendingFinancialOperation> begin({
    required String userId,
    required String householdId,
    required String kind,
    required String payloadHash,
  }) async => throw StateError('disk full');
}

const _recordLabel = 'Record';
const _failure = 'Failed to record payment. Please try again.';

Widget _app({
  required SharedPreferences prefs,
  required _FakeRepository repo,
  required Widget form,
  Future<FinancialRequestStore> Function()? openStore,
}) {
  return ProviderScope(
    overrides: [
      expenseMembersProvider('hh').overrideWith(
        (ref) async => [
          const ExpenseMember(userId: 'u0', displayName: 'Member 0'),
          const ExpenseMember(userId: 'u1', displayName: 'Member 1'),
        ],
      ),
      currentUserIdProvider.overrideWithValue('u0'),
      expenseRepositoryProvider.overrideWithValue(repo),
      financialRequestStoreProvider.overrideWith(
        (ref) => (openStore ?? () async => FinancialRequestStore(prefs))(),
      ),
    ],
    child: MaterialApp(
      theme: appTheme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => form)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _record(WidgetTester tester, {String? amount}) async {
  if (amount != null) {
    await tester.enterText(find.byType(TextField).first, amount);
    await tester.pump();
  }
  await tester.tap(find.widgetWithText(TextButton, _recordLabel));
  await tester.pumpAndSettle();
}

Future<SharedPreferences> _prefs(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  return (await tester.runAsync(SharedPreferences.getInstance))!;
}

void main() {
  group('request identity helpers', () {
    test('generateRequestId yields RFC 4122 v4 UUIDs', () {
      final v4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final ids = {for (var i = 0; i < 500; i++) generateRequestId()};
      expect(ids, hasLength(500));
      expect(ids.every(v4.hasMatch), isTrue);
    });

    test('generateRequestId is deterministic for a seeded generator', () {
      expect(generateRequestId(Random(7)), generateRequestId(Random(7)));
    });

    test('payloadFingerprint is stable and sensitive to every part', () {
      final base = payloadFingerprint(['h', 'a', 'b', '1250', 'EUR', '']);
      expect(payloadFingerprint(['h', 'a', 'b', '1250', 'EUR', '']), base);
      expect(
        payloadFingerprint(['h', 'a', 'b', '1251', 'EUR', '']),
        isNot(base),
      );
      expect(
        payloadFingerprint(['h', 'b', 'a', '1250', 'EUR', '']),
        isNot(base),
      );
      expect(
        payloadFingerprint(['h', 'a', 'b', '1250', 'EUR', 'x']),
        isNot(base),
      );
      expect(base, matches(RegExp(r'^[0-9a-f]{16}$')));
    });
  });

  group('failure classification', () {
    FinancialSubmitOutcome of(Object e) => classifyFinancialSubmitError(e);

    test('server refusals are definite', () {
      expect(
        of(PostgrestException(message: 'm', code: 'HE003')),
        FinancialSubmitOutcome.rejected,
      );
      expect(
        of(PostgrestException(message: 'm', code: '42501')),
        FinancialSubmitOutcome.rejected,
      );
      expect(
        of(PostgrestException(message: 'm', code: 'PGRST202')),
        FinancialSubmitOutcome.rejected,
      );
    });

    test('HF002 and HF003 are reported distinctly', () {
      expect(
        of(PostgrestException(message: 'm', code: 'HF003')),
        FinancialSubmitOutcome.alreadyRemoved,
      );
      expect(
        of(PostgrestException(message: 'm', code: 'HF002')),
        FinancialSubmitOutcome.keyReused,
      );
    });

    test(
      'connection-loss SQLSTATE classes may hide a commit, so stay ambiguous',
      () {
        for (final code in ['08006', '08003', '57P01', '58030', 'XX000']) {
          expect(
            of(PostgrestException(message: 'm', code: code)),
            FinancialSubmitOutcome.ambiguous,
            reason: code,
          );
        }
        // Errors raised before any write remain definite.
        expect(
          of(PostgrestException(message: 'm', code: '23505')),
          FinancialSubmitOutcome.rejected,
        );
        expect(
          of(PostgrestException(message: 'm', code: '57014')),
          FinancialSubmitOutcome.rejected,
        );
      },
    );

    test('network loss, timeouts and gateway statuses are ambiguous', () {
      expect(
        of(const SocketException('offline')),
        FinancialSubmitOutcome.ambiguous,
      );
      expect(of(TimeoutException('slow')), FinancialSubmitOutcome.ambiguous);
      expect(of(StateError('no client')), FinancialSubmitOutcome.ambiguous);
      expect(
        of(PostgrestException(message: 'm', code: '503')),
        FinancialSubmitOutcome.ambiguous,
      );
      expect(
        of(PostgrestException(message: 'm')),
        FinancialSubmitOutcome.ambiguous,
      );
    });
  });

  group('FinancialRequestStore', () {
    const scope = (userId: 'u0', householdId: 'hh', kind: 'settlement');

    Future<PendingFinancialOperation> begin(
      FinancialRequestStore store,
      String hash, {
      String kind = 'settlement',
    }) => store.begin(
      userId: 'u0',
      householdId: 'hh',
      kind: kind,
      payloadHash: hash,
    );

    List<PendingFinancialOperation> pending(FinancialRequestStore store) =>
        store.pending(
          userId: scope.userId,
          householdId: scope.householdId,
          kind: scope.kind,
        );

    test(
      'survives a restart, is scoped, and stores no financial details',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final op = await begin(
          FinancialRequestStore(prefs),
          payloadFingerprint(['hh', 'u0', 'u1', '1250']),
        );

        // "Restart": a brand new store over the same persisted preferences.
        final second = FinancialRequestStore(prefs);
        final found = second.findByHash(
          userId: 'u0',
          householdId: 'hh',
          kind: 'settlement',
          payloadHash: op.payloadHash,
        );
        expect(found?.requestId, op.requestId);

        expect(pending(second), hasLength(1));
        expect(
          second.pending(userId: 'u1', householdId: 'hh', kind: 'settlement'),
          isEmpty,
        );
        expect(
          second.pending(
            userId: 'u0',
            householdId: 'other',
            kind: 'settlement',
          ),
          isEmpty,
        );
        expect(
          second.pending(userId: 'u0', householdId: 'hh', kind: 'expense'),
          isEmpty,
        );

        final stored = prefs.getKeys().map(prefs.getString).join();
        expect(stored.contains('1250'), isFalse);

        await second.remove(
          userId: 'u0',
          householdId: 'hh',
          kind: 'settlement',
          requestId: op.requestId,
        );
        expect(pending(second), isEmpty);
        expect(prefs.getKeys(), isEmpty);
      },
    );

    test('a second unresolved operation never replaces the first', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final a = await begin(FinancialRequestStore(prefs), 'hashA');
      final b = await begin(FinancialRequestStore(prefs), 'hashB');

      final restarted = FinancialRequestStore(prefs);
      expect(pending(restarted).map((o) => o.requestId), [
        a.requestId,
        b.requestId,
      ]);
      expect(a.requestId, isNot(b.requestId));

      await restarted.remove(
        userId: 'u0',
        householdId: 'hh',
        kind: 'settlement',
        requestId: a.requestId,
      );
      expect(pending(restarted).map((o) => o.requestId), [b.requestId]);
    });

    test('acknowledging stops prompts but keeps every identity', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = FinancialRequestStore(prefs);
      await begin(store, 'hashA');
      expect(
        store.hasUnacknowledged(
          userId: 'u0',
          householdId: 'hh',
          kind: 'settlement',
        ),
        isTrue,
      );
      await store.acknowledgeAll(
        userId: 'u0',
        householdId: 'hh',
        kind: 'settlement',
      );
      expect(
        store.hasUnacknowledged(
          userId: 'u0',
          householdId: 'hh',
          kind: 'settlement',
        ),
        isFalse,
      );
      expect(pending(store), hasLength(1));
    });

    test(
      'a full registry keeps every identity and rejects only the new one',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = FinancialRequestStore(prefs);
        final ids = <String>[];
        for (var i = 0; i < FinancialRequestStore.maxPending; i++) {
          ids.add((await begin(store, 'h$i')).requestId);
        }
        expect(pending(store).map((o) => o.requestId), ids);

        final before = prefs.getString('pending_financial_op/settlement/u0/hh');
        await expectLater(
          begin(store, 'one-too-many'),
          throwsA(isA<FinancialPendingLimitException>()),
        );
        expect(
          prefs.getString('pending_financial_op/settlement/u0/hh'),
          before,
        );

        // Restart: every identity is still there, in order.
        expect(
          pending(FinancialRequestStore(prefs)).map((o) => o.requestId),
          ids,
        );

        // Resolving one frees exactly one slot for a new submission.
        await store.remove(
          userId: 'u0',
          householdId: 'hh',
          kind: 'settlement',
          requestId: ids[3],
        );
        final fresh = await begin(store, 'now-it-fits');
        expect(pending(store).map((o) => o.requestId), [
          ...ids.where((id) => id != ids[3]),
          fresh.requestId,
        ]);
      },
    );

    test('resolving B never removes A', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = FinancialRequestStore(prefs);
      final a = await begin(store, 'A');
      final b = await begin(store, 'B');
      await store.remove(
        userId: 'u0',
        householdId: 'hh',
        kind: 'settlement',
        requestId: b.requestId,
      );
      expect(pending(store).map((o) => o.requestId), [a.requestId]);
    });

    test('overlapping local updates cannot lose each other', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = FinancialRequestStore(prefs);
      final seed = await begin(store, 'seed');

      // Fired together, with no await in between: begin x8, a removal, an ack,
      // issued through two store instances over the same preferences.
      final other = FinancialRequestStore(prefs);
      final started = [
        for (var i = 0; i < 8; i++)
          (i.isEven ? store : other).begin(
            userId: 'u0',
            householdId: 'hh',
            kind: 'settlement',
            payloadHash: 'c$i',
          ),
      ];
      final removal = other.remove(
        userId: 'u0',
        householdId: 'hh',
        kind: 'settlement',
        requestId: seed.requestId,
      );
      final ack = store.acknowledgeAll(
        userId: 'u0',
        householdId: 'hh',
        kind: 'settlement',
      );
      final created = await Future.wait(started);
      await removal;
      await ack;

      final left = pending(FinancialRequestStore(prefs));
      expect(
        left.map((o) => o.requestId).toSet(),
        created.map((o) => o.requestId).toSet(),
      );
      expect(left, hasLength(8));
      expect(left.any((o) => o.requestId == seed.requestId), isFalse);
    });

    test('a corrupt value is ignored rather than crashing', () async {
      SharedPreferences.setMockInitialValues({
        'pending_financial_op/settlement/u0/hh': '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(pending(FinancialRequestStore(prefs)), isEmpty);
    });
  });

  group('settlement form submissions', () {
    testWidgets('an ambiguous failure is retried with the same request id', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([const SocketException('lost'), null]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);

      await _record(tester, amount: '12.50');
      expect(find.text(_failure), findsOneWidget);
      expect(find.text('12.50'), findsOneWidget);

      await _record(tester);
      expect(repo.settlementIds, hasLength(2));
      expect(repo.settlementIds[0], isNotNull);
      expect(repo.settlementIds[1], repo.settlementIds[0]);
      expect(
        prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
        isEmpty,
      );
    });

    testWidgets(
      'the same id is used after the form was closed and the app restarted',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository([const SocketException('lost'), null]);
        await tester.pumpWidget(
          _app(
            prefs: prefs,
            repo: repo,
            form: const SettlementFormScreen(householdId: 'hh'),
          ),
        );
        await _open(tester);
        await _record(tester, amount: '12.50');

        // Process death: the whole widget tree and every provider are discarded.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _app(
            prefs: prefs,
            repo: repo,
            form: const SettlementFormScreen(householdId: 'hh'),
          ),
        );
        await _open(tester);
        await _record(tester, amount: '12.50');

        expect(repo.settlementIds, hasLength(2));
        expect(repo.settlementIds[1], repo.settlementIds[0]);
      },
    );

    testWidgets('a definite refusal does not keep the id', (tester) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([
        PostgrestException(message: 'no', code: 'HS007'),
        null,
      ]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);

      await _record(tester, amount: '12.50');
      expect(
        prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
        isEmpty,
      );
      await _record(tester);
      expect(repo.settlementIds[1], isNot(repo.settlementIds[0]));
    });

    testWidgets('a new submission after success gets a new id', (tester) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([null, null]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );

      await _open(tester);
      await _record(tester, amount: '12.50');
      await _open(tester);
      await _record(tester, amount: '12.50');

      expect(repo.settlementIds, hasLength(2));
      expect(repo.settlementIds[1], isNot(repo.settlementIds[0]));
    });

    testWidgets('changing the details after an unconfirmed attempt asks first', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([const SocketException('lost'), null]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);
      await _record(tester, amount: '12.50');

      await tester.enterText(find.byType(TextField).first, '13.00');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, _recordLabel));
      // The submit spinner animates behind the dialog, so settle by time.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Earlier attempt not confirmed'), findsOneWidget);
      expect(repo.settlementIds, hasLength(1));

      // Declining sends nothing and keeps the pending id for the original details.
      await tester.tap(find.text('Check history'));
      await tester.pumpAndSettle();
      expect(repo.settlementIds, hasLength(1));

      await tester.tap(find.widgetWithText(TextButton, _recordLabel));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Record as new'));
      await tester.pumpAndSettle();
      expect(repo.settlementIds, hasLength(2));
      expect(repo.settlementIds[1], isNot(repo.settlementIds[0]));
      expect(repo.settlementAmounts, [1250, 1300]);
    });

    testWidgets('HF003 is explained and clears the pending id', (tester) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([
        PostgrestException(message: 'gone', code: 'HF003'),
      ]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);
      await _record(tester, amount: '12.50');

      expect(
        find.text('This was already recorded and has since been removed.'),
        findsOneWidget,
      );
      expect(
        prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
        isEmpty,
      );
    });

    testWidgets('HF002 is explained', (tester) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([
        PostgrestException(message: 'diff', code: 'HF002'),
      ]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);
      await _record(tester, amount: '12.50');

      expect(
        find.text(
          'This entry was already used with different details. Please try again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a second tap while a request is pending sends nothing more', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final gate = Completer<void>();
      final repo = _FakeRepository([gate]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const SettlementFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);
      await tester.enterText(find.byType(TextField).first, '12.50');
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, _recordLabel));
      await tester.pump();
      // While pending the Save button is replaced, so a second tap is impossible.
      expect(find.widgetWithText(TextButton, _recordLabel), findsNothing);
      expect(repo.settlementIds, hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.settlementIds, hasLength(1));
    });
  });

  group('durable identity safety', () {
    const form = SettlementFormScreen(householdId: 'hh');

    testWidgets('storage that cannot be opened blocks the send', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: form,
          openStore: () async => throw StateError('unavailable'),
        ),
      );
      await _open(tester);
      await _record(tester, amount: '12.50');

      expect(repo.settlementIds, isEmpty);
      expect(find.text(_failure), findsOneWidget);
    });

    testWidgets(
      'storage that never answers blocks the send after two seconds',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository([]);
        await tester.pumpWidget(
          _app(
            prefs: prefs,
            repo: repo,
            form: form,
            openStore: () => Completer<FinancialRequestStore>().future,
          ),
        );
        await _open(tester);
        await tester.enterText(find.byType(TextField).first, '12.50');
        await tester.pump();
        await tester.tap(find.widgetWithText(TextButton, _recordLabel));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();

        expect(repo.settlementIds, isEmpty);
        expect(find.text(_failure), findsOneWidget);
      },
    );

    testWidgets('an unsaved identity is never sent', (tester) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: form,
          openStore: () async => _FailingStore(prefs),
        ),
      );
      await _open(tester);
      await _record(tester, amount: '12.50');

      expect(repo.settlementIds, isEmpty);
      expect(find.text(_failure), findsOneWidget);
    });

    testWidgets(
      'A stays recoverable after B was recorded as new and the app restarted',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository([
          const SocketException('lost A'),
          const SocketException('lost B'),
          null,
          null,
        ]);
        Future<void> launch() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(_app(prefs: prefs, repo: repo, form: form));
          await _open(tester);
        }

        await launch();
        await _record(tester, amount: '12.50'); // A, response lost
        await tester.enterText(find.byType(TextField).first, '13.00');
        await tester.pump();
        await tester.tap(find.widgetWithText(TextButton, _recordLabel));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Record as new'));
        await tester.pumpAndSettle(); // B, response lost
        final idA = repo.settlementIds[0];
        final idB = repo.settlementIds[1];
        expect(idA, isNot(idB));

        // App restarts before B is resolved: both identities must survive.
        await launch();
        await _record(tester, amount: '12.50'); // exactly A again
        expect(repo.settlementIds[2], idA);
        await launch();
        await _record(tester, amount: '13.00'); // exactly B again
        expect(repo.settlementIds[3], idB);
        expect(
          prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
          isEmpty,
        );
      },
    );

    testWidgets(
      'after Record as new the user is not nagged again, and identities are kept',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository([
          const SocketException('lost'),
          null,
          null,
        ]);
        await tester.pumpWidget(_app(prefs: prefs, repo: repo, form: form));
        await _open(tester);
        await _record(tester, amount: '12.50');

        await tester.enterText(find.byType(TextField).first, '13.00');
        await tester.pump();
        await tester.tap(find.widgetWithText(TextButton, _recordLabel));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Record as new'));
        await tester.pumpAndSettle();
        expect(repo.settlementIds, hasLength(2));

        await _open(tester);
        await _record(tester, amount: '14.00');
        expect(find.text('Earlier attempt not confirmed'), findsNothing);
        expect(repo.settlementIds, hasLength(3));
        final left = prefs.getString('pending_financial_op/settlement/u0/hh');
        expect(
          left,
          isNotNull,
        ); // the unresolved first attempt is still recoverable
      },
    );
  });

  group('registry capacity and independent resolution', () {
    const form = SettlementFormScreen(householdId: 'hh');

    testWidgets('a full registry blocks the new RPC and keeps every identity', (
      tester,
    ) async {
      final entries = [
        for (var i = 0; i < FinancialRequestStore.maxPending; i++)
          {'id': 'id-$i', 'hash': 'old$i', 'ack': true},
      ];
      const key = 'pending_financial_op/settlement/u0/hh';
      SharedPreferences.setMockInitialValues({key: jsonEncode(entries)});
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      final repo = _FakeRepository([]);
      await tester.pumpWidget(_app(prefs: prefs, repo: repo, form: form));
      await _open(tester);
      await _record(tester, amount: '77.00');

      expect(repo.settlementIds, isEmpty);
      expect(
        find.text(
          'Too many earlier entries are still unconfirmed. Check the history and try again later.',
        ),
        findsOneWidget,
      );
      expect(jsonDecode(prefs.getString(key)!), entries);
    });

    testWidgets('a successful retry clears only its own identity', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([
        const SocketException('lost A'),
        const SocketException('lost B'),
        null,
      ]);
      await tester.pumpWidget(_app(prefs: prefs, repo: repo, form: form));
      await _open(tester);
      await _record(tester, amount: '12.50'); // A unresolved
      await tester.enterText(find.byType(TextField).first, '13.00');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, _recordLabel));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Record as new'));
      await tester.pumpAndSettle(); // B unresolved

      await _record(tester, amount: '12.50'); // A succeeds on retry
      final left = FinancialRequestStore(
        prefs,
      ).pending(userId: 'u0', householdId: 'hh', kind: 'settlement');
      expect(left.map((o) => o.requestId), [repo.settlementIds[1]]);
    });
  });

  group('expense form submissions', () {
    testWidgets('an ambiguous failure is retried with the same request id', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository([const SocketException('lost'), null]);
      await tester.pumpWidget(
        _app(
          prefs: prefs,
          repo: repo,
          form: const ExpenseFormScreen(householdId: 'hh'),
        ),
      );
      await _open(tester);

      await tester.enterText(find.byType(TextField).at(0), '12.50');
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(
        find.text('Failed to add expense. Please try again.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();
      expect(repo.expenseIds, hasLength(2));
      expect(repo.expenseIds[0], isNotNull);
      expect(repo.expenseIds[1], repo.expenseIds[0]);
    });
  });
}
