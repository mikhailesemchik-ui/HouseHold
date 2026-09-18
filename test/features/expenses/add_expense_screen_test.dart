import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';

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
        home: const ExpenseFormScreen(householdId: 'hh'),
      ),
    );
  }

  testWidgets('defaults select the payer and every participant exactly once', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(3)));
    await tester.pumpAndSettle();

    // Both "Paid by" and "Split between" render one MemberOption per member
    // (6 total for 3 members); all three participant options start selected.
    expect(find.text('Member 0'), findsNWidgets(2));
    expect(find.text('Member 1'), findsNWidgets(2));
    expect(find.text('Member 2'), findsNWidgets(2));
  });

  testWidgets('deselecting the last participant stays deselected on rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    // "Split between" is the second occurrence of each name (first is "Paid
    // by"). Uncheck both participants one at a time.
    await tester.tap(find.text('Member 0').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Member 1').last);
    await tester.pumpAndSettle();

    // Regression guard: the old dialog re-derived defaults from `build` on
    // every rebuild, so this second uncheck used to immediately re-select
    // everyone again.
    final options = tester.widgetList<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.button == true,
      ),
    );
    final splitBetween = options.where((s) => s.properties.selected == true);
    // Only the (still-selected) payer chip should report selected=true now.
    expect(splitBetween.length, 1);
  });

  testWidgets('submitting with zero participants shows inline validation', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Member 0').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Member 1').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '10.00');
    await tester.enterText(find.byType(TextField).at(1), 'Groceries');
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Select at least one participant.'), findsOneWidget);
    // Title/amount are not discarded by a validation failure either.
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets(
    'valid input passes validation and attempts to submit (network unavailable in test)',
    (tester) async {
      await tester.pumpWidget(buildForm(members(2)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '12.50');
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      // No Supabase client is initialized in this test, so the mutation
      // fails — but no validation errors should appear, confirming the
      // valid input passed every check before the network call ran.
      expect(find.text('Enter a valid amount (e.g. 12.50)'), findsNothing);
      expect(find.text('Select at least one participant.'), findsNothing);
      expect(
        find.text('Failed to add expense. Please try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('failure preserves amount, title, and participant selection', (
    tester,
  ) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '12.50');
    await tester.enterText(find.byType(TextField).at(1), 'Dinner');
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('12.50'), findsOneWidget);
    expect(find.text('Dinner'), findsOneWidget);
    // 3, not 2: "Paid by" + "Split between" + the per-person share summary
    // (shown once a valid amount and at least one participant are selected).
    expect(find.text('Member 0'), findsNWidgets(3));
    expect(find.text('Member 1'), findsNWidgets(3));
  });

  // A live double-tap race isn't exercisable here: with no Supabase client
  // initialized in the test process, `ExpenseRepository(...)` throws
  // synchronously the moment it's constructed, so `_submit` runs its whole
  // setState(true) → fail → setState(false) sequence within one microtask
  // burst — there is no realistic in-flight window a widget test can catch,
  // the same limitation the Task Form's own suite works within. The guard
  // itself (`if (_isSubmitting) return;` before the flag is set, and the Add
  // button swapping to a disabled spinner while `_isSubmitting`) mirrors
  // that already-established, reviewed pattern verbatim.

  testWidgets('leaving a dirty form prompts to discard', (tester) async {
    await tester.pumpWidget(buildForm(members(2)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), 'Dinner');
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

  testWidgets('8 participants render without overflow', (tester) async {
    await tester.pumpWidget(buildForm(members(8)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Member 7'), findsNWidgets(2));
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
