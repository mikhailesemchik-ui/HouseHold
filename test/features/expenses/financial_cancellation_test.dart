import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/domain/archived_entry.dart';
import 'package:household_os/features/expenses/domain/cancellation_preview.dart';
import 'package:household_os/features/expenses/domain/expense_permissions.dart';
import 'package:household_os/features/expenses/presentation/widgets/archive_section.dart';
import 'package:household_os/features/expenses/presentation/widgets/cancel_financial_dialog.dart';
import 'package:household_os/features/expenses/presentation/widgets/history_row.dart';

import 'expenses_test.dart' show makeExpense, makeSettlement;

Widget _host(Widget child) => MaterialApp(
  theme: appTheme,
  home: Scaffold(body: child),
);

Map<String, dynamic> _archiveMap({
  String kind = 'expense',
  String? reason,
  Map<String, dynamic>? snapshot,
}) => {
  'id': 'a1',
  'kind': kind,
  'canceled_by_name': 'Alice',
  'canceled_at': '2026-10-27T10:30:00Z',
  'reason': reason,
  'snapshot':
      snapshot ?? {'title': 'Dinner', 'amount_cents': 1001, 'currency': 'EUR'},
};

void main() {
  group('canCancelSettlement mirrors the server rule', () {
    final s = makeSettlement(); // user-b pays user-a, created by user-b

    test('sender, recipient, creator and owner may cancel', () {
      expect(canCancelSettlement(s, 'user-b', isOwner: false), isTrue);
      expect(canCancelSettlement(s, 'user-a', isOwner: false), isTrue);
      expect(canCancelSettlement(s, 'someone', isOwner: true), isTrue);
    });

    test('an unrelated member or signed-out user may not', () {
      expect(canCancelSettlement(s, 'user-c', isOwner: false), isFalse);
      expect(canCancelSettlement(s, '', isOwner: true), isFalse);
    });
  });

  group('cancellationBalanceChanges', () {
    test('cancelling an expense moves both members and uses real balances', () {
      final changes = cancellationBalanceChanges(
        expenses: [makeExpense()],
        settlements: const [],
        expenseId: 'e-1',
      );
      expect(changes.map((c) => c.userId), containsAll(['user-a', 'user-b']));
      final alice = changes.firstWhere((c) => c.userId == 'user-a');
      expect(alice.beforeCents, 500);
      expect(alice.afterCents, 0);
    });

    test('cancelling a payment that over-settled reverses the sign', () {
      final changes = cancellationBalanceChanges(
        expenses: [makeExpense()],
        settlements: [makeSettlement(amountCents: 800)],
        settlementId: 's-1',
      );
      final alice = changes.firstWhere((c) => c.userId == 'user-a');
      expect(alice.beforeCents, -300);
      expect(alice.afterCents, 500);
      expect(alice.reversesSign, isTrue);
    });

    test(
      'an expense cancellation leaves existing payments in the calculation',
      () {
        final changes = cancellationBalanceChanges(
          expenses: [makeExpense()],
          settlements: [makeSettlement()],
          expenseId: 'e-1',
        );
        final alice = changes.firstWhere((c) => c.userId == 'user-a');
        expect(alice.afterCents, -500); // the 500 payment still counts
      },
    );

    test('no preview when records use another currency', () {
      expect(
        cancellationBalanceChanges(
          expenses: [makeExpense(currency: 'USD')],
          settlements: const [],
          expenseId: 'e-1',
        ),
        isEmpty,
      );
    });
  });

  group('ArchivedEntry', () {
    test('reads an archived expense', () {
      final e = ArchivedEntry.fromMap(_archiveMap(reason: 'typo'));
      expect(e.isExpense, isTrue);
      expect(e.title, 'Dinner');
      expect(e.amountCents, 1001);
      expect(e.canceledByName, 'Alice');
      expect(e.reason, 'typo');
    });

    test('reads an archived payment and an absent reason', () {
      final e = ArchivedEntry.fromMap(
        _archiveMap(
          kind: 'settlement',
          snapshot: {
            'from_name': 'Bob',
            'to_name': 'Alice',
            'amount_cents': 500,
            'currency': 'EUR',
          },
        ),
      );
      expect(e.isExpense, isFalse);
      expect(e.title, 'Bob paid Alice');
      expect(e.reason, isNull);
    });
  });

  group('ArchiveSection', () {
    testWidgets('is collapsed, then shows actor, amount and reason', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ArchiveSection(
            entries: [ArchivedEntry.fromMap(_archiveMap(reason: 'typo'))],
          ),
        ),
      );
      expect(find.text('Cancelled entries (1)'), findsOneWidget);
      expect(find.textContaining('Cancelled by Alice'), findsNothing);

      await tester.tap(find.text('Cancelled entries (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Expense: Dinner · €10.01'), findsOneWidget);
      expect(find.textContaining('Cancelled by Alice'), findsOneWidget);
      expect(find.textContaining('typo'), findsOneWidget);
    });

    testWidgets('renders nothing when there are no cancelled entries', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const ArchiveSection(entries: [])));
      expect(find.byType(ExpansionTile), findsNothing);
    });
  });

  group('cancel dialog', () {
    Future<CancelDecision?> open(
      WidgetTester tester, {
      List<BalanceChange> changes = const [],
      String? reason,
      String tap = 'Cancel expense',
    }) async {
      CancelDecision? result;
      var done = false;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCancelFinancialDialog(
                  context,
                  title: 'Cancel expense?',
                  confirmLabel: 'Cancel expense',
                  changes: changes,
                  currentUserId: 'user-a',
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (reason != null) {
        await tester.enterText(find.byType(TextField), reason);
      }
      await tester.tap(find.widgetWithText(FilledButton, tap));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return result;
    }

    testWidgets('warns that recorded payments are not cancelled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCancelFinancialDialog(
                context,
                title: 'Cancel expense?',
                confirmLabel: 'Cancel expense',
                changes: const [],
                currentUserId: 'u',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not cancelled'), findsOneWidget);
      expect(find.text('Reason (optional)'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
    });

    testWidgets('confirming without a reason returns a null reason', (
      tester,
    ) async {
      final decision = await open(tester);
      expect(decision, isNotNull);
      expect(decision!.reason, isNull);
    });

    testWidgets('confirming with a reason returns it trimmed', (tester) async {
      final decision = await open(tester, reason: '  wrong amount ');
      expect(decision!.reason, 'wrong amount');
    });

    testWidgets('keeping the entry returns nothing', (tester) async {
      CancelDecision? result = const CancelDecision('x');
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCancelFinancialDialog(
                  context,
                  title: 'Cancel expense?',
                  confirmLabel: 'Cancel expense',
                  changes: const [],
                  currentUserId: 'u',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('shows balance changes from the member perspective', (
      tester,
    ) async {
      final changes = cancellationBalanceChanges(
        expenses: [makeExpense()],
        settlements: [makeSettlement(amountCents: 800)],
        settlementId: 's-1',
      );
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCancelFinancialDialog(
                context,
                title: 'Cancel payment?',
                confirmLabel: 'Cancel payment',
                changes: changes,
                currentUserId: 'user-a',
                isExpense: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text('You: owes €3.00 → owed €5.00 (reversed)'),
        findsOneWidget,
      );
      expect(find.textContaining('Bob: owed €3.00'), findsOneWidget);
    });
  });

  group('settlement row actions', () {
    Future<void> pump(
      WidgetTester tester,
      String userId, {
      bool isOwner = false,
    }) {
      return tester.pumpWidget(
        _host(
          SettlementHistoryRow(
            settlement: makeSettlement(),
            currentUserId: userId,
            isOwner: isOwner,
          ),
        ),
      );
    }

    for (final (user, owner) in [
      ('user-b', false),
      ('user-a', false),
      ('user-z', true),
    ]) {
      testWidgets('$user (owner: $owner) can cancel the payment', (
        tester,
      ) async {
        await pump(tester, user, isOwner: owner);
        await tester.tap(find.byTooltip('Settlement actions'));
        await tester.pumpAndSettle();
        expect(find.text('Cancel payment'), findsOneWidget);
        expect(find.text('Delete'), findsNothing);
      });
    }

    testWidgets('an unrelated member sees no actions', (tester) async {
      await pump(tester, 'user-c');
      expect(find.byTooltip('Settlement actions'), findsNothing);
    });
  });
}
