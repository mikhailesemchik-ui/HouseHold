import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/expense_permissions.dart';
import 'package:household_os/features/expenses/presentation/widgets/history_row.dart';

const _creator = 'creator';
const _payer = 'payer';
const _participant = 'participant';
const _owner = 'owner';
const _stranger = 'stranger';

Expense _expense() => Expense(
  id: 'e1',
  householdId: 'h1',
  title: 'Groceries',
  amountCents: 3000,
  currency: 'EUR',
  paidBy: _payer,
  paidByDisplayName: 'Pat',
  createdBy: _creator,
  createdAt: DateTime.utc(2026, 10, 27),
  updatedAt: DateTime.utc(2026, 10, 27),
  participants: const [
    ExpenseParticipant(
      expenseId: 'e1',
      userId: _payer,
      displayName: 'Pat',
      shareCents: 1500,
    ),
    ExpenseParticipant(
      expenseId: 'e1',
      userId: _participant,
      displayName: 'Pia',
      shareCents: 1500,
    ),
  ],
);

Future<void> _pumpRow(
  WidgetTester tester, {
  required String userId,
  bool isOwner = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: ExpenseHistoryRow(
          expense: _expense(),
          currentUserId: userId,
          isOwner: isOwner,
        ),
      ),
    ),
  );
}

void main() {
  group('expense permission rules (mirror the database policies)', () {
    final e = _expense();

    test('title edit: creator, payer, participant and owner', () {
      expect(canEditExpenseTitle(e, _creator, isOwner: false), isTrue);
      expect(canEditExpenseTitle(e, _payer, isOwner: false), isTrue);
      expect(canEditExpenseTitle(e, _participant, isOwner: false), isTrue);
      expect(canEditExpenseTitle(e, _owner, isOwner: true), isTrue);
    });

    test('title edit: unrelated member and signed-out user are refused', () {
      expect(canEditExpenseTitle(e, _stranger, isOwner: false), isFalse);
      expect(canEditExpenseTitle(e, '', isOwner: true), isFalse);
    });

    test('delete: creator, payer and owner only', () {
      expect(canDeleteExpense(e, _creator, isOwner: false), isTrue);
      expect(canDeleteExpense(e, _payer, isOwner: false), isTrue);
      expect(canDeleteExpense(e, _owner, isOwner: true), isTrue);
      expect(canDeleteExpense(e, _participant, isOwner: false), isFalse);
      expect(canDeleteExpense(e, _stranger, isOwner: false), isFalse);
      expect(canDeleteExpense(e, '', isOwner: true), isFalse);
    });
  });

  group('ExpenseHistoryRow actions', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Expense actions'));
      await tester.pumpAndSettle();
    }

    testWidgets('creator sees edit and delete', (tester) async {
      await _pumpRow(tester, userId: _creator);
      await openMenu(tester);
      expect(find.text('Edit title'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('payer sees edit and delete', (tester) async {
      await _pumpRow(tester, userId: _payer);
      await openMenu(tester);
      expect(find.text('Edit title'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('owner sees edit and delete', (tester) async {
      await _pumpRow(tester, userId: _owner, isOwner: true);
      await openMenu(tester);
      expect(find.text('Edit title'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('participant can only edit the title', (tester) async {
      await _pumpRow(tester, userId: _participant);
      await openMenu(tester);
      expect(find.text('Edit title'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('unrelated member sees no actions and the row stays intact', (
      tester,
    ) async {
      await _pumpRow(tester, userId: _stranger);
      expect(find.byTooltip('Expense actions'), findsNothing);
      expect(find.text('Groceries'), findsOneWidget);
    });
  });

  group('server authorization errors', () {
    test('a write that matched no row is reported as a permission error', () {
      expect(
        () => ExpenseRepository.ensureAffected(const []),
        throwsA(isA<ExpensePermissionException>()),
      );
    });

    test('a write that matched a row passes', () {
      expect(
        () => ExpenseRepository.ensureAffected(const [
          {'id': 'e1'},
        ]),
        returnsNormally,
      );
    });
  });
}
