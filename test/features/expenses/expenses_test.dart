import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/balance.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/money.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/expenses_screen.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ExpenseParticipant makeParticipant({
  String expenseId = 'e-1',
  required String userId,
  String? displayName,
  required int shareCents,
}) {
  return ExpenseParticipant(
    expenseId: expenseId,
    userId: userId,
    displayName: displayName ?? 'User $userId',
    shareCents: shareCents,
  );
}

Expense makeExpense({
  String id = 'e-1',
  String householdId = 'hh-1',
  String title = 'Groceries',
  int amountCents = 1000,
  String currency = 'EUR',
  String paidBy = 'user-a',
  String paidByDisplayName = 'Alice',
  List<ExpenseParticipant>? participants,
  DateTime? createdAt,
}) {
  final ts = createdAt ?? DateTime.utc(2026, 8, 27, 10);
  return Expense(
    id: id,
    householdId: householdId,
    title: title,
    amountCents: amountCents,
    currency: currency,
    paidBy: paidBy,
    paidByDisplayName: paidByDisplayName,
    createdBy: paidBy,
    createdAt: ts,
    updatedAt: ts,
    participants:
        participants ??
        [
          makeParticipant(expenseId: id, userId: 'user-a', shareCents: 500),
          makeParticipant(expenseId: id, userId: 'user-b', shareCents: 500),
        ],
  );
}

Settlement makeSettlement({
  String id = 's-1',
  String householdId = 'hh-1',
  String fromUserId = 'user-b',
  String fromName = 'Bob',
  String toUserId = 'user-a',
  String toName = 'Alice',
  int amountCents = 500,
  String currency = 'EUR',
  String? note,
  DateTime? createdAt,
}) {
  return Settlement(
    id: id,
    householdId: householdId,
    fromUserId: fromUserId,
    fromName: fromName,
    toUserId: toUserId,
    toName: toName,
    amountCents: amountCents,
    currency: currency,
    note: note,
    createdBy: fromUserId,
    createdAt: createdAt ?? DateTime.utc(2026, 8, 28, 10),
  );
}

/// [navBarHeight] wraps the screen in a stand-in for the app shell — the same
/// `Scaffold(extendBody: true)` + bottom navigation arrangement that publishes
/// the nav bar's measured height as `MediaQuery.padding.bottom`.
///
/// [settlementsStream] defaults to an empty, never-erroring stream so tests
/// that only care about expenses don't have to think about settlements.
Widget buildScreen(
  Stream<List<Expense>> stream, {
  double? navBarHeight,
  Stream<List<Settlement>>? settlementsStream,
}) {
  const screen = ExpensesScreen(householdId: 'test-hh');
  return ProviderScope(
    overrides: [
      expensesProvider('test-hh').overrideWith((ref) => stream),
      settlementsProvider(
        'test-hh',
      ).overrideWith((ref) => settlementsStream ?? Stream.value(const [])),
      currentUserIdProvider.overrideWithValue('test-user'),
    ],
    child: MaterialApp(
      theme: appTheme,
      home: navBarHeight == null
          ? screen
          : Scaffold(
              extendBody: true,
              bottomNavigationBar: SizedBox(height: navBarHeight),
              body: screen,
            ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Money parsing
// ---------------------------------------------------------------------------

void main() {
  group('Money.parseAmountCents', () {
    test('parses integer amount', () {
      expect(Money.parseAmountCents('82'), 8200);
    });

    test('parses one decimal place', () {
      expect(Money.parseAmountCents('82.4'), 8240);
    });

    test('parses two decimal places', () {
      expect(Money.parseAmountCents('82.40'), 8240);
    });

    test('parses small cents amount', () {
      expect(Money.parseAmountCents('0.01'), 1);
    });

    test('returns null for empty string', () {
      expect(Money.parseAmountCents(''), isNull);
    });

    test('returns null for whitespace', () {
      expect(Money.parseAmountCents('   '), isNull);
    });

    test('returns null for zero', () {
      expect(Money.parseAmountCents('0'), isNull);
    });

    test('returns null for zero amount (0.00)', () {
      expect(Money.parseAmountCents('0.00'), isNull);
    });

    test('returns null for more than 2 decimal places', () {
      expect(Money.parseAmountCents('10.123'), isNull);
    });

    test('returns null for non-numeric input', () {
      expect(Money.parseAmountCents('abc'), isNull);
    });

    test('returns null for negative amount', () {
      expect(Money.parseAmountCents('-10'), isNull);
    });

    test('trims surrounding whitespace', () {
      expect(Money.parseAmountCents('  10.50  '), 1050);
    });
  });

  // ---------------------------------------------------------------------------
  // Money formatting
  // ---------------------------------------------------------------------------

  group('Money.format', () {
    test('formats EUR amount correctly', () {
      expect(Money.format(8240, 'EUR'), '€82.40');
    });

    test('formats USD amount correctly', () {
      expect(Money.format(500, 'USD'), '\$5.00');
    });

    test('formats amount with zero cents', () {
      expect(Money.format(1000, 'EUR'), '€10.00');
    });

    test('formats small amount', () {
      expect(Money.format(1, 'EUR'), '€0.01');
    });

    test('uses currency code as symbol fallback for unknown currency', () {
      expect(Money.format(500, 'CHF'), 'CHF5.00');
    });
  });

  // ---------------------------------------------------------------------------
  // Equal split shares
  // ---------------------------------------------------------------------------

  group('Money.equalSplitShares', () {
    test('exact division distributes equally', () {
      final shares = Money.equalSplitShares(900, 3);
      expect(shares, [300, 300, 300]);
    });

    test('remainder goes to first participant', () {
      final shares = Money.equalSplitShares(1000, 3);
      expect(shares, [334, 333, 333]);
    });

    test('remainder of 2 cents spread across first two', () {
      final shares = Money.equalSplitShares(1001, 3);
      expect(shares, [334, 334, 333]);
    });

    test('single participant gets full amount', () {
      final shares = Money.equalSplitShares(500, 1);
      expect(shares, [500]);
    });

    test('shares sum to original amount', () {
      for (final count in [2, 3, 5, 7]) {
        final amount = 999;
        final shares = Money.equalSplitShares(amount, count);
        expect(shares.fold(0, (s, x) => s + x), amount);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Balance calculation
  // ---------------------------------------------------------------------------

  group('calculateNetBalances', () {
    test('payer gets credit for full amount', () {
      final expense = makeExpense(
        amountCents: 1000,
        paidBy: 'user-a',
        participants: [
          makeParticipant(userId: 'user-a', shareCents: 500),
          makeParticipant(userId: 'user-b', shareCents: 500),
        ],
      );
      final balances = calculateNetBalances([expense], []);
      // user-a paid 1000, owes 500 → net = +500
      expect(balances['user-a']!.netCents, 500);
      // user-b owes 500 → net = -500
      expect(balances['user-b']!.netCents, -500);
    });

    test('balances sum to zero', () {
      final expenses = [
        makeExpense(
          id: 'e-1',
          amountCents: 900,
          paidBy: 'user-a',
          participants: [
            makeParticipant(
              expenseId: 'e-1',
              userId: 'user-a',
              shareCents: 300,
            ),
            makeParticipant(
              expenseId: 'e-1',
              userId: 'user-b',
              shareCents: 300,
            ),
            makeParticipant(
              expenseId: 'e-1',
              userId: 'user-c',
              shareCents: 300,
            ),
          ],
        ),
        makeExpense(
          id: 'e-2',
          amountCents: 600,
          paidBy: 'user-b',
          participants: [
            makeParticipant(
              expenseId: 'e-2',
              userId: 'user-a',
              shareCents: 200,
            ),
            makeParticipant(
              expenseId: 'e-2',
              userId: 'user-b',
              shareCents: 200,
            ),
            makeParticipant(
              expenseId: 'e-2',
              userId: 'user-c',
              shareCents: 200,
            ),
          ],
        ),
      ];
      final balances = calculateNetBalances(expenses, []);
      final total = balances.values.fold(0, (s, b) => s + b.netCents);
      expect(total, 0);
    });

    test('payer not in participants still has correct net', () {
      final expense = makeExpense(
        amountCents: 600,
        paidBy: 'user-a',
        // payer (user-a) is not in participant list
        participants: [
          makeParticipant(userId: 'user-b', shareCents: 300),
          makeParticipant(userId: 'user-c', shareCents: 300),
        ],
      );
      final balances = calculateNetBalances([expense], []);
      // user-a paid 600, owes nothing → net = +600
      expect(balances['user-a']!.netCents, 600);
      // user-b owes 300 → net = -300
      expect(balances['user-b']!.netCents, -300);
      // user-c owes 300 → net = -300
      expect(balances['user-c']!.netCents, -300);
    });

    test('empty expense list returns empty map', () {
      final balances = calculateNetBalances([], []);
      expect(balances, isEmpty);
    });

    test('uses display name from participants', () {
      final expense = makeExpense(
        paidBy: 'user-a',
        paidByDisplayName: 'Alice',
        participants: [
          makeParticipant(
            userId: 'user-b',
            displayName: 'Bob',
            shareCents: 500,
          ),
        ],
      );
      final balances = calculateNetBalances([expense], []);
      expect(balances['user-b']!.displayName, 'Bob');
    });
  });

  // ---------------------------------------------------------------------------
  // Simplify debts
  // ---------------------------------------------------------------------------

  group('simplifyDebts', () {
    test('produces correct pairwise debt', () {
      final balances = {
        'user-a': const MemberBalance(
          userId: 'user-a',
          displayName: 'Alice',
          netCents: 500,
        ),
        'user-b': const MemberBalance(
          userId: 'user-b',
          displayName: 'Bob',
          netCents: -500,
        ),
      };
      final debts = simplifyDebts(balances);
      expect(debts.length, 1);
      expect(debts.first.fromUserId, 'user-b');
      expect(debts.first.toUserId, 'user-a');
      expect(debts.first.amountCents, 500);
    });

    test('returns empty list for balanced state', () {
      final balances = {
        'user-a': const MemberBalance(
          userId: 'user-a',
          displayName: 'Alice',
          netCents: 0,
        ),
      };
      final debts = simplifyDebts(balances);
      expect(debts, isEmpty);
    });

    test('3-person chain collapses to 1 transaction', () {
      // A owes 300 net; C is owed 300 net; B is even.
      // Greedy: A → C for 300. One transaction, not two.
      final balances = {
        'user-a': const MemberBalance(
          userId: 'user-a',
          displayName: 'Alice',
          netCents: -300,
        ),
        'user-b': const MemberBalance(
          userId: 'user-b',
          displayName: 'Bob',
          netCents: 0,
        ),
        'user-c': const MemberBalance(
          userId: 'user-c',
          displayName: 'Carol',
          netCents: 300,
        ),
      };
      final debts = simplifyDebts(balances);
      expect(debts.length, 1);
      expect(debts.first.fromUserId, 'user-a');
      expect(debts.first.toUserId, 'user-c');
      expect(debts.first.amountCents, 300);
    });

    test('3 debtors to 1 creditor uses 3 transactions', () {
      final balances = {
        'user-a': const MemberBalance(
          userId: 'user-a',
          displayName: 'Alice',
          netCents: 3000,
        ),
        'user-b': const MemberBalance(
          userId: 'user-b',
          displayName: 'Bob',
          netCents: -1000,
        ),
        'user-c': const MemberBalance(
          userId: 'user-c',
          displayName: 'Carol',
          netCents: -1000,
        ),
        'user-d': const MemberBalance(
          userId: 'user-d',
          displayName: 'Dave',
          netCents: -1000,
        ),
      };
      final debts = simplifyDebts(balances);
      expect(debts.length, 3);
      expect(debts.every((d) => d.toUserId == 'user-a'), isTrue);
      expect(debts.fold(0, (s, d) => s + d.amountCents), 3000);
    });

    test(
      'cross-debt between 2 creditors and 2 debtors produces 2 transactions',
      () {
        // A +200, B +100, C -200, D -100
        // Optimal: C→A 200, D→B 100 (2 transactions)
        final balances = {
          'user-a': const MemberBalance(
            userId: 'user-a',
            displayName: 'Alice',
            netCents: 200,
          ),
          'user-b': const MemberBalance(
            userId: 'user-b',
            displayName: 'Bob',
            netCents: 100,
          ),
          'user-c': const MemberBalance(
            userId: 'user-c',
            displayName: 'Carol',
            netCents: -200,
          ),
          'user-d': const MemberBalance(
            userId: 'user-d',
            displayName: 'Dave',
            netCents: -100,
          ),
        };
        final debts = simplifyDebts(balances);
        expect(debts.length, 2);
        expect(debts.fold(0, (s, d) => s + d.amountCents), 300);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Expense.fromMap
  // ---------------------------------------------------------------------------

  group('Expense.fromMap', () {
    test('parses all fields correctly', () {
      final map = {
        'id': 'exp-1',
        'household_id': 'hh-1',
        'title': 'Dinner',
        'amount_cents': 5000,
        'currency': 'EUR',
        'paid_by': 'user-a',
        'paid_by_display_name': 'Alice',
        'created_by': 'user-a',
        'created_at': '2026-08-27T18:00:00.000Z',
        'updated_at': '2026-08-27T18:00:00.000Z',
      };
      final expense = Expense.fromMap(map, []);
      expect(expense.id, 'exp-1');
      expect(expense.title, 'Dinner');
      expect(expense.amountCents, 5000);
      expect(expense.currency, 'EUR');
      expect(expense.paidBy, 'user-a');
      expect(expense.paidByDisplayName, 'Alice');
      expect(expense.participants, isEmpty);
    });

    test('uses Deleted member fallback when paid_by_display_name is null', () {
      final map = {
        'id': 'exp-1',
        'household_id': 'hh-1',
        'title': 'Lunch',
        'amount_cents': 1000,
        'currency': 'EUR',
        'paid_by': 'user-x',
        'paid_by_display_name': null,
        'created_by': 'user-x',
        'created_at': '2026-08-27T12:00:00.000Z',
        'updated_at': '2026-08-27T12:00:00.000Z',
      };
      final expense = Expense.fromMap(map, []);
      expect(expense.paidByDisplayName, 'Deleted member');
    });
  });

  // ---------------------------------------------------------------------------
  // ExpenseRepository.validateTitle
  // ---------------------------------------------------------------------------

  group('ExpenseRepository.validateTitle', () {
    test('returns null for a valid title', () {
      expect(ExpenseRepository.validateTitle('Groceries'), isNull);
    });

    test('returns error for empty string', () {
      expect(ExpenseRepository.validateTitle(''), isNotNull);
    });

    test('returns error for whitespace-only string', () {
      expect(ExpenseRepository.validateTitle('   '), isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // resolveExpensesLoadState — the correctness rule that a balance is never
  // computed from partial data.
  // ---------------------------------------------------------------------------

  group('resolveExpensesLoadState', () {
    test('either stream loading → loading', () {
      expect(
        resolveExpensesLoadState(
          const AsyncValue.loading(),
          AsyncValue.data(const []),
        ),
        ExpensesLoadState.loading,
      );
      expect(
        resolveExpensesLoadState(
          AsyncValue.data(const []),
          const AsyncValue.loading(),
        ),
        ExpensesLoadState.loading,
      );
    });

    test('expenses error takes priority and is reported distinctly', () {
      expect(
        resolveExpensesLoadState(
          AsyncValue.error(Exception('boom'), StackTrace.empty),
          AsyncValue.data(const []),
        ),
        ExpensesLoadState.expensesError,
      );
    });

    test('a settlements-only error still blocks the ready state', () {
      expect(
        resolveExpensesLoadState(
          AsyncValue.data([makeExpense()]),
          AsyncValue.error(Exception('boom'), StackTrace.empty),
        ),
        ExpensesLoadState.settlementsError,
      );
    });

    test('both streams with data → ready', () {
      expect(
        resolveExpensesLoadState(
          AsyncValue.data([makeExpense()]),
          AsyncValue.data([makeSettlement()]),
        ),
        ExpensesLoadState.ready,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Widget tests
  // ---------------------------------------------------------------------------

  group('ExpensesScreen widget', () {
    testWidgets('shows real screen shell with local loading while pending', (
      tester,
    ) async {
      final controller = StreamController<List<Expense>>();
      await tester.pumpWidget(buildScreen(controller.stream));
      await tester.pump();
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add expense'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      controller.close();
    });

    testWidgets('settled state and empty history show together', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen(Stream.value(const [])));
      await tester.pumpAndSettle();
      expect(find.text('You are settled up'), findsOneWidget);
      expect(find.text('No expenses yet'), findsOneWidget);
    });

    testWidgets('actions stay visible when history is empty', (tester) async {
      await tester.pumpWidget(buildScreen(Stream.value(const [])));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Add expense'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Record settlement'),
        findsOneWidget,
      );
    });

    testWidgets('shows expense title in list', (tester) async {
      final expenses = [makeExpense(title: 'Dinner out')];
      await tester.pumpWidget(buildScreen(Stream.value(expenses)));
      await tester.pumpAndSettle();
      expect(find.text('Dinner out'), findsOneWidget);
    });

    testWidgets('shows formatted amount', (tester) async {
      final expenses = [makeExpense(amountCents: 2550)];
      await tester.pumpWidget(buildScreen(Stream.value(expenses)));
      await tester.pumpAndSettle();
      expect(find.text('€25.50'), findsOneWidget);
    });

    testWidgets('debt state names the relationship before the amount', (
      tester,
    ) async {
      final expenses = [
        makeExpense(
          id: 'e1',
          amountCents: 1000,
          paidBy: 'user-a',
          paidByDisplayName: 'Alice',
          participants: [
            makeParticipant(
              expenseId: 'e1',
              userId: 'test-user',
              displayName: 'Me',
              shareCents: 500,
            ),
            makeParticipant(
              expenseId: 'e1',
              userId: 'user-a',
              displayName: 'Alice',
              shareCents: 500,
            ),
          ],
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(expenses)));
      await tester.pumpAndSettle();
      // test-user (the current user override) owes Alice 500 cents.
      expect(find.text('You owe Alice'), findsOneWidget);
      expect(find.text('€5.00'), findsWidgets);
    });

    testWidgets('multiple relevant debts are all shown, not just one', (
      tester,
    ) async {
      final expenses = [
        makeExpense(
          id: 'e1',
          amountCents: 1000,
          paidBy: 'user-a',
          paidByDisplayName: 'Alice',
          participants: [
            makeParticipant(
              expenseId: 'e1',
              userId: 'test-user',
              displayName: 'Me',
              shareCents: 1000,
            ),
          ],
        ),
        makeExpense(
          id: 'e2',
          amountCents: 500,
          paidBy: 'user-b',
          paidByDisplayName: 'Bob',
          participants: [
            makeParticipant(
              expenseId: 'e2',
              userId: 'test-user',
              displayName: 'Me',
              shareCents: 500,
            ),
          ],
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(expenses)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alice'), findsWidgets);
      expect(find.textContaining('Bob'), findsWidgets);
    });

    // Regression coverage for a Phase D presentation bug: `BalanceBlock` was
    // filtering `simplifyDebts`' full household output down to only the
    // debts touching the current user, silently hiding a real debt between
    // two other members. `simplifyDebts`/`calculateNetBalances` have no
    // notion of "current user" — they compute the household's full debt
    // graph — and `docs/manual_test_scenarios.md`'s SETTLE-04 scenario
    // ("A owes B; C owes A") describes exactly this multi-relationship
    // household state as normal product behaviour. The screen must show the
    // full picture, with the viewer's own relationship emphasized.
    testWidgets(
      'a debt between two other members remains visible alongside the '
      "current user's own debt",
      (tester) async {
        final expenses = [
          // Me (test-user) owes Alice — the current user's own debt.
          makeExpense(
            id: 'e1',
            amountCents: 1000,
            paidBy: 'user-a',
            paidByDisplayName: 'Alice',
            participants: [
              makeParticipant(
                expenseId: 'e1',
                userId: 'test-user',
                displayName: 'Me',
                shareCents: 1000,
              ),
            ],
          ),
          // Carol owes Bob — a debt between two other members that does not
          // involve the current user at all.
          makeExpense(
            id: 'e2',
            amountCents: 700,
            paidBy: 'user-b',
            paidByDisplayName: 'Bob',
            participants: [
              makeParticipant(
                expenseId: 'e2',
                userId: 'user-c',
                displayName: 'Carol',
                shareCents: 700,
              ),
            ],
          ),
        ];
        await tester.pumpWidget(buildScreen(Stream.value(expenses)));
        await tester.pumpAndSettle();

        // The current user's own relationship, in first-person wording.
        expect(find.text('You owe Alice'), findsOneWidget);
        // The other members' relationship is still shown — never hidden —
        // and worded in third person, naming both people (never "you").
        expect(find.text('Carol owes Bob'), findsOneWidget);
        // The screen must never claim a false "settled" state while any
        // household debt — personal or not — remains.
        expect(find.text('You are settled up'), findsNothing);
      },
    );

    testWidgets(
      'the current user has no personal debt but the household is not '
      'settled — no false settled claim is shown',
      (tester) async {
        final expenses = [
          // Bob paid, Carol owes Bob. The current user is not a participant
          // and did not pay, so their own net balance is exactly zero.
          makeExpense(
            id: 'e1',
            amountCents: 400,
            paidBy: 'user-b',
            paidByDisplayName: 'Bob',
            participants: [
              makeParticipant(
                expenseId: 'e1',
                userId: 'user-c',
                displayName: 'Carol',
                shareCents: 400,
              ),
            ],
          ),
        ];
        await tester.pumpWidget(buildScreen(Stream.value(expenses)));
        await tester.pumpAndSettle();

        expect(find.text('You are settled up'), findsNothing);
        expect(find.text('Carol owes Bob'), findsOneWidget);
      },
    );

    testWidgets('merges expenses and settlements into one chronology', (
      tester,
    ) async {
      final expense = makeExpense(
        id: 'e1',
        title: 'Groceries',
        createdAt: DateTime.utc(2026, 8, 27),
      );
      final settlement = makeSettlement(
        id: 's1',
        fromName: 'Bob',
        toName: 'Alice',
        createdAt: DateTime.utc(2026, 8, 28),
      );
      await tester.pumpWidget(
        buildScreen(
          Stream.value([expense]),
          settlementsStream: Stream.value([settlement]),
        ),
      );
      await tester.pumpAndSettle();

      final settlementY = tester.getTopLeft(find.text('Bob paid Alice')).dy;
      final expenseY = tester.getTopLeft(find.text('Groceries')).dy;
      // The settlement (2026-08-28) is newer than the expense (2026-08-27),
      // so it must render above it in the merged, most-recent-first feed.
      expect(settlementY, lessThan(expenseY));
    });

    testWidgets(
      'settlement and expense rows announce relationship + amount as one unit',
      (tester) async {
        final expense = makeExpense(id: 'e1', title: 'Groceries');
        final settlement = makeSettlement(
          id: 's1',
          fromName: 'Bob',
          toName: 'Alice',
          amountCents: 1000,
        );
        await tester.pumpWidget(
          buildScreen(
            Stream.value([expense]),
            settlementsStream: Stream.value([settlement]),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.bySemanticsLabel('Bob paid Alice, €10.00'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(r'^Groceries, paid by .+, .+, €10\.00$'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a settlements load error blocks the balance instead of showing a false one',
      (tester) async {
        // Exercised as a direct unit test of `resolveExpensesLoadState`
        // rather than through a live provider/stream override: this
        // Riverpod version does not reliably surface an overridden
        // `StreamProvider.autoDispose.family`'s error state inside the
        // widget-test harness (confirmed via an isolated minimal
        // reproduction outside this app entirely — the state never leaves
        // `loading` no matter how the error is raised). The decision this
        // guards is a pure function specifically so it can be verified this
        // way regardless of that harness limitation.
        final state = resolveExpensesLoadState(
          AsyncValue.data([makeExpense()]),
          AsyncValue.error(Exception('boom'), StackTrace.empty),
        );
        expect(state, ExpensesLoadState.settlementsError);
      },
    );

    testWidgets('long expense title does not overflow', (tester) async {
      final expenses = [
        makeExpense(
          title:
              'A very long grocery shopping trip title that keeps going '
              'and going and going',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(expenses)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow at 2.0x text scale', (tester) async {
      final expenses = [
        makeExpense(
          title: 'Groceries',
          amountCents: 999999,
          paidByDisplayName: 'A Household Member With A Long Name',
        ),
      ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: buildScreen(Stream.value(expenses)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('list clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;

      double bottomPadding() {
        final listView = tester.widget<ListView>(find.byType(ListView));
        return (listView.padding! as EdgeInsets).bottom;
      }

      await tester.pumpWidget(buildScreen(Stream.value(const [])));
      await tester.pump();
      final withoutShell = bottomPadding();

      await tester.pumpWidget(
        buildScreen(Stream.value(const []), navBarHeight: navBarHeight),
      );
      await tester.pump();
      final withShell = bottomPadding();

      expect(withShell - withoutShell, navBarHeight);
    });
  });

  // ---------------------------------------------------------------------------
  // Settlement balance integration
  // ---------------------------------------------------------------------------

  group('calculateNetBalances with settlements', () {
    test('settlement reduces debt for payer and credit for receiver', () {
      final expense = makeExpense(
        amountCents: 1000,
        paidBy: 'user-a',
        participants: [
          makeParticipant(userId: 'user-a', shareCents: 500),
          makeParticipant(userId: 'user-b', shareCents: 500),
        ],
      );
      // user-b owes user-a 500 cents; settlement records user-b paying user-a 500
      final settlement = makeSettlement(
        fromUserId: 'user-b',
        toUserId: 'user-a',
        amountCents: 500,
      );
      final balances = calculateNetBalances([expense], [settlement]);
      // After settlement: user-a: +1000 - 500 - 500 = 0, user-b: -500 + 500 = 0
      expect(balances['user-a']!.netCents, 0);
      expect(balances['user-b']!.netCents, 0);
    });

    test('partial settlement leaves remaining debt', () {
      final expense = makeExpense(
        amountCents: 1000,
        paidBy: 'user-a',
        participants: [
          makeParticipant(userId: 'user-a', shareCents: 500),
          makeParticipant(userId: 'user-b', shareCents: 500),
        ],
      );
      final settlement = makeSettlement(
        fromUserId: 'user-b',
        toUserId: 'user-a',
        amountCents: 300,
      );
      final balances = calculateNetBalances([expense], [settlement]);
      expect(balances['user-a']!.netCents, 200);
      expect(balances['user-b']!.netCents, -200);
    });

    test('settlement-only map sums to zero', () {
      final settlement = makeSettlement(amountCents: 750);
      final balances = calculateNetBalances([], [settlement]);
      final total = balances.values.fold(0, (s, b) => s + b.netCents);
      expect(total, 0);
    });
  });
}
