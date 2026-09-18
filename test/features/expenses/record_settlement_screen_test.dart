import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';

void main() {
  List<ExpenseMember> members(int count) => [
    for (var i = 0; i < count; i++)
      ExpenseMember(userId: 'u$i', displayName: 'Member $i'),
  ];

  Widget buildForm(List<ExpenseMember> members) {
    return ProviderScope(
      overrides: [
        expenseMembersProvider('hh').overrideWith((ref) async => members),
        currentUserIdProvider.overrideWithValue('u0'),
      ],
      child: MaterialApp(
        theme: appTheme,
        home: const SettlementFormScreen(householdId: 'hh'),
      ),
    );
  }

  testWidgets('defaults pick two distinct members for From and To', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(3)));
    await tester.pumpAndSettle();

    expect(find.text('From'), findsOneWidget);
    expect(find.text('To'), findsOneWidget);
    // Every member appears once under "From" and once under "To".
    expect(find.text('Member 0'), findsNWidgets(2));
    expect(find.text('Member 1'), findsNWidgets(2));
  });

  testWidgets('selecting the same member for From and To is rejected', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    // "To" defaults to Member 1 (distinct from the From default, Member 0).
    // Selecting Member 0 under "To" makes both the same member.
    await tester.tap(find.text('Member 0').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '10.00');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Record'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Select two different members.'), findsOneWidget);
  });

  testWidgets(
    'valid Money.parseAmountCents input passes validation (network unavailable in test)',
    (tester) async {
      await tester.pumpWidget(buildForm(members(2)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '12.50');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Record'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid amount (e.g. 12.50)'), findsNothing);
      expect(find.text('Select two different members.'), findsNothing);
      expect(
        find.text('Failed to record payment. Please try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a comma decimal separator is rejected — Money.parseAmountCents does '
    'not accept it, and the settlement form no longer has its own parser',
    (tester) async {
      await tester.pumpWidget(buildForm(members(2)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '12,50');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Record'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid amount (e.g. 12.50)'), findsOneWidget);
    },
  );

  testWidgets('more than two decimal places is rejected', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '12.505');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Record'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount (e.g. 12.50)'), findsOneWidget);
  });

  testWidgets('non-numeric input is rejected', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Record'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount (e.g. 12.50)'), findsOneWidget);
  });

  testWidgets('failure preserves the entered amount and note', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '12.50');
    await tester.enterText(find.byType(TextField).last, 'For dinner');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Record'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('12.50'), findsOneWidget);
    expect(find.text('For dinner'), findsOneWidget);
  });

  testWidgets('leaving a dirty form prompts to discard', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '12.50');
    await tester.pumpAndSettle();

    final popScope =
        tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).single
            as PopScope;
    expect(popScope.canPop, isFalse);
  });

  testWidgets('a pristine form can be left without a prompt', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    final popScope =
        tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).single
            as PopScope;
    expect(popScope.canPop, isTrue);
  });

  testWidgets('fewer than two members shows a quiet explanation', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(1)));
    await tester.pumpAndSettle();

    expect(
      find.text('At least two active members are needed to record a payment.'),
      findsOneWidget,
    );
  });

  testWidgets('renders without overflow at 2.0x text scale', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: buildForm(members(5)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
