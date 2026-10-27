import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/expenses/data/financial_submit_outcome.dart';
import 'package:household_os/features/expenses/domain/balance.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/money.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/amount_input.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'expenses_test.dart' show buildScreen, makeExpense, makeSettlement;

class _FakeRepository implements ExpenseRepository {
  _FakeRepository([this.failure]);

  final Exception? failure;
  int settlementCalls = 0;
  int expenseCalls = 0;

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
    settlementCalls++;
    if (failure != null) throw failure!;
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
    expenseCalls++;
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _form(Widget form, _FakeRepository repo, SharedPreferences prefs) {
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
        (ref) async => FinancialRequestStore(prefs),
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

Future<SharedPreferences> _prefs(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  return (await tester.runAsync(SharedPreferences.getInstance))!;
}

Future<void> _submitSettlement(WidgetTester tester, String amount) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, amount);
  await tester.pump();
  await tester.tap(find.widgetWithText(TextButton, 'Record'));
  await tester.pumpAndSettle();
}

Future<void> _submitExpense(WidgetTester tester, String amount) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), amount);
  await tester.enterText(find.byType(TextField).at(1), 'Dinner');
  await tester.tap(find.widgetWithText(TextButton, 'Add'));
  await tester.pumpAndSettle();
}

const _tooLarge = 'The amount cannot exceed €1,000,000.00';

void main() {
  group('Money.parseAmountCents limits', () {
    test('the maximum is exactly 100000000 cents, inclusive', () {
      expect(Money.maxCents, 100000000);
      expect(Money.parseAmountCents('1000000'), 100000000);
      expect(Money.parseAmountCents('1000000.00'), 100000000);
      expect(Money.parseAmountCents('999999.99'), 99999999);
      expect(Money.parseAmountCents('1000000.01'), isNull);
      expect(Money.exceedsMaximum('1000000.01'), isTrue);
      expect(Money.exceedsMaximum('1000000.00'), isFalse);
      expect(Money.parseAmountCents('1000001'), isNull);
    });

    test('very long digit strings are rejected without wrapping around', () {
      final cases = [
        '92233720368547758', // 2^63 / 100: used to wrap when multiplied by 100
        '92233720368547759.99',
        '184467440737095516', // 2^64 / 100
        '9' * 40,
        '9' * 40 + '.99',
        '1${'0' * 300}',
        '9' * 5000,
      ];
      for (final input in cases) {
        expect(Money.parseAmountCents(input), isNull, reason: input);
        expect(Money.exceedsMaximum(input), isTrue, reason: input);
      }
    });

    test('leading zeros never make a valid amount look too large', () {
      expect(Money.parseAmountCents('${'0' * 500}12.5'), 1250);
      expect(Money.parseAmountCents('${'0' * 500}1000000'), 100000000);
      expect(Money.parseAmountCents('0' * 500), isNull);
      expect(Money.exceedsMaximum('${'0' * 500}12.5'), isFalse);
    });

    test('existing valid decimal parsing is unchanged', () {
      expect(Money.parseAmountCents('82'), 8200);
      expect(Money.parseAmountCents('82.4'), 8240);
      expect(Money.parseAmountCents('82.40'), 8240);
      expect(Money.parseAmountCents('0.01'), 1);
      expect(Money.parseAmountCents('  10.50  '), 1050);
      expect(Money.parseAmountCents('12.'), 1200);
    });

    test('malformed input is invalid, not too large', () {
      for (final input in [
        '',
        ' ',
        'abc',
        '-10',
        '+5',
        '1e3',
        '1.2.3',
        '10.123',
        '10.-5',
        '٣٤',
      ]) {
        expect(Money.parseAmountCents(input), isNull, reason: input);
        expect(Money.exceedsMaximum(input), isFalse, reason: input);
      }
    });
  });

  group('amountInputError', () {
    test(
      'returns the right message for each failure and null for valid input',
      () {
        expect(amountInputError('12.50', TargetPlatform.android), isNull);
        expect(amountInputError('1000000', TargetPlatform.android), isNull);
        expect(
          amountInputError('abc', TargetPlatform.android),
          'Enter a valid amount (e.g. 12.50)',
        );
        expect(
          amountInputError('1000000.01', TargetPlatform.android),
          _tooLarge,
        );
        expect(amountInputError('9' * 40, TargetPlatform.android), _tooLarge);
      },
    );

    test('iOS comma decimals are checked after normalization', () {
      expect(amountInputError('12,50', TargetPlatform.iOS), isNull);
      expect(amountInputError('1000000,01', TargetPlatform.iOS), _tooLarge);
      expect(
        amountInputError('12,50', TargetPlatform.android),
        'Enter a valid amount (e.g. 12.50)',
      );
    });
  });

  group('server refusals', () {
    FinancialSubmitOutcome of(String code) => classifyFinancialSubmitError(
      PostgrestException(message: 'm', code: code),
    );

    test('currency and amount refusals are recognised as definite', () {
      expect(of('HE008'), FinancialSubmitOutcome.currencyMismatch);
      expect(of('HS009'), FinancialSubmitOutcome.currencyMismatch);
      expect(of('HE009'), FinancialSubmitOutcome.amountTooLarge);
      expect(of('HS010'), FinancialSubmitOutcome.amountTooLarge);
    });
  });

  group('forms', () {
    testWidgets(
      'the settlement form blocks an oversized amount before any request',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository();
        await tester.pumpWidget(
          _form(const SettlementFormScreen(householdId: 'hh'), repo, prefs),
        );
        await _submitSettlement(tester, '1000000.01');

        expect(find.text(_tooLarge), findsOneWidget);
        expect(repo.settlementCalls, 0);
        expect(
          prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
          isEmpty,
        );
      },
    );

    testWidgets('the settlement form sends exactly the maximum', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository();
      await tester.pumpWidget(
        _form(const SettlementFormScreen(householdId: 'hh'), repo, prefs),
      );
      await _submitSettlement(tester, '1000000');

      expect(find.text(_tooLarge), findsNothing);
      expect(repo.settlementCalls, 1);
    });

    testWidgets('the settlement form survives a absurdly long number', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository();
      await tester.pumpWidget(
        _form(const SettlementFormScreen(householdId: 'hh'), repo, prefs),
      );
      await _submitSettlement(tester, '9' * 60);

      expect(find.text(_tooLarge), findsOneWidget);
      expect(repo.settlementCalls, 0);
    });

    testWidgets(
      'the expense form blocks an oversized amount before any request',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository();
        await tester.pumpWidget(
          _form(const ExpenseFormScreen(householdId: 'hh'), repo, prefs),
        );
        await _submitExpense(tester, '5000000');

        expect(find.text(_tooLarge), findsOneWidget);
        expect(repo.expenseCalls, 0);
      },
    );

    testWidgets(
      'a currency refusal from the server is explained and not retried',
      (tester) async {
        final prefs = await _prefs(tester);
        final repo = _FakeRepository(
          PostgrestException(message: 'currency', code: 'HS009'),
        );
        await tester.pumpWidget(
          _form(const SettlementFormScreen(householdId: 'hh'), repo, prefs),
        );
        await _submitSettlement(tester, '12.50');

        expect(
          find.text(
            "This entry's currency does not match the household currency.",
          ),
          findsOneWidget,
        );
        expect(
          prefs.getKeys().where((k) => k.startsWith('pending_financial_op')),
          isEmpty,
        );
      },
    );

    testWidgets('an amount refusal from the server is explained', (
      tester,
    ) async {
      final prefs = await _prefs(tester);
      final repo = _FakeRepository(
        PostgrestException(message: 'big', code: 'HE009'),
      );
      await tester.pumpWidget(
        _form(const ExpenseFormScreen(householdId: 'hh'), repo, prefs),
      );
      await _submitExpense(tester, '12.50');

      expect(find.text(_tooLarge), findsOneWidget);
    });
  });

  group('balances and legacy currencies', () {
    test(
      'hasForeignCurrency flags expenses or settlements outside EUR only',
      () {
        expect(
          hasForeignCurrency([makeExpense()], [makeSettlement()]),
          isFalse,
        );
        expect(
          hasForeignCurrency([makeExpense(currency: 'USD')], const []),
          isTrue,
        );
        expect(
          hasForeignCurrency(const [], [makeSettlement(currency: 'GBP')]),
          isTrue,
        );
        expect(hasForeignCurrency(const [], const []), isFalse);
      },
    );

    testWidgets('EUR-only households show the balance exactly as before', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen(Stream.value([makeExpense()])));
      await tester.pumpAndSettle();

      expect(find.textContaining('€5.00'), findsWidgets);
      expect(find.textContaining('different currency'), findsNothing);
    });

    testWidgets(
      'a legacy non-EUR record suppresses the combined balance but stays listed',
      (tester) async {
        await tester.pumpWidget(
          buildScreen(
            Stream.value([
              makeExpense(id: 'e-eur'),
              makeExpense(
                id: 'e-usd',
                title: 'Legacy USD',
                currency: 'USD',
                amountCents: 2000,
              ),
            ]),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('different currency'), findsOneWidget);
        expect(find.text('Legacy USD'), findsOneWidget);
        expect(find.text('\$20.00'), findsOneWidget);
        expect(find.textContaining('owes'), findsNothing);
      },
    );

    testWidgets(
      'a legacy non-EUR settlement is not netted into an EUR balance',
      (tester) async {
        await tester.pumpWidget(
          buildScreen(
            Stream.value([makeExpense()]),
            settlementsStream: Stream.value([makeSettlement(currency: 'USD')]),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('different currency'), findsOneWidget);
      },
    );
  });
}
