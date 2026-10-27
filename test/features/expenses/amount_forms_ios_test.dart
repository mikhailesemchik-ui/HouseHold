import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';

const _invalidAmount = 'Enter a valid amount (e.g. 12.50)';

Widget _host(
  Widget screen, {
  required TargetPlatform platform,
  double width = 414,
  double textScale = 1,
}) {
  final members = [
    for (var i = 0; i < 2; i++)
      ExpenseMember(userId: 'u$i', displayName: 'Member $i'),
  ];
  return ProviderScope(
    overrides: [
      expenseMembersProvider('hh').overrideWith((ref) async => members),
      currentUserIdProvider.overrideWithValue('u0'),
    ],
    child: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        theme: appTheme.copyWith(platform: platform),
        home: screen,
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required TargetPlatform platform,
  double width = 414,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _host(screen, platform: platform, width: width, textScale: textScale),
  );
  await tester.pumpAndSettle();
}

bool _hasFocus(WidgetTester tester, int fieldIndex) => tester
    .widget<TextField>(find.byType(TextField).at(fieldIndex))
    .focusNode!
    .hasFocus;

void main() {
  const addExpense = ExpenseFormScreen(householdId: 'hh');
  const settlement = SettlementFormScreen(householdId: 'hh');

  group('comma amounts', () {
    testWidgets('iOS: Add expense accepts 12,50 and reaches the save call', (
      tester,
    ) async {
      await _pump(tester, addExpense, platform: TargetPlatform.iOS);
      await tester.enterText(find.byType(TextField).at(0), '12,50');
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text(_invalidAmount), findsNothing);
      // No Supabase client in tests, so the save itself fails after
      // validation passed — and the typed text is preserved.
      expect(
        find.text('Failed to add expense. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('12,50'), findsOneWidget);
    });

    testWidgets('Android: Add expense still rejects 12,50', (tester) async {
      await _pump(tester, addExpense, platform: TargetPlatform.android);
      await tester.enterText(find.byType(TextField).at(0), '12,50');
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text(_invalidAmount), findsOneWidget);
    });

    testWidgets('iOS: Record settlement accepts 12,50', (tester) async {
      await _pump(tester, settlement, platform: TargetPlatform.iOS);
      await tester.enterText(find.byType(TextField).first, '12,50');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Record'));
      await tester.pumpAndSettle();

      expect(find.text(_invalidAmount), findsNothing);
      expect(
        find.text('Failed to record payment. Please try again.'),
        findsOneWidget,
      );
    });

    testWidgets('iOS: required-field validation is preserved', (tester) async {
      await _pump(tester, addExpense, platform: TargetPlatform.iOS);
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text(_invalidAmount), findsOneWidget);
    });
  });

  group('keyboard dismissal', () {
    testWidgets('iOS: tapping empty space unfocuses and keeps the text', (
      tester,
    ) async {
      await _pump(tester, addExpense, platform: TargetPlatform.iOS);
      await tester.enterText(find.byType(TextField).at(0), '12,50');
      expect(_hasFocus(tester, 0), isTrue);

      // The spacer between the title field and "Paid by" is empty space.
      await tester.tapAt(const Offset(8, 700));
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, 0), isFalse);
      expect(find.text('12,50'), findsOneWidget);
      expect(
        find.text('Failed to add expense. Please try again.'),
        findsNothing,
      );
    });

    testWidgets('iOS: focus moves between amount and title by tapping', (
      tester,
    ) async {
      await _pump(tester, addExpense, platform: TargetPlatform.iOS);
      await tester.tap(find.byType(TextField).at(0));
      await tester.pump();
      expect(_hasFocus(tester, 0), isTrue);

      await tester.tap(find.byType(TextField).at(1));
      await tester.pump();
      expect(_hasFocus(tester, 1), isTrue);
      expect(_hasFocus(tester, 0), isFalse);
    });

    testWidgets('Android: tapping empty space leaves focus alone', (
      tester,
    ) async {
      await _pump(tester, addExpense, platform: TargetPlatform.android);
      await tester.enterText(find.byType(TextField).at(0), '12.50');
      await tester.tapAt(const Offset(8, 700));
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, 0), isTrue);
    });

    testWidgets('iOS: Record settlement dismisses on tap too', (tester) async {
      await _pump(tester, settlement, platform: TargetPlatform.iOS);
      await tester.enterText(find.byType(TextField).first, '12,50');
      expect(_hasFocus(tester, 0), isTrue);

      await tester.tapAt(const Offset(8, 760));
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, 0), isFalse);
      expect(find.text('12,50'), findsOneWidget);
    });
  });

  group('hero amount centering', () {
    for (final width in [337.0, 414.0]) {
      for (final amount in ['', '12,50', '1234567.89']) {
        testWidgets('is centred as a whole at ${width}dp with "$amount"', (
          tester,
        ) async {
          await _pump(
            tester,
            addExpense,
            platform: TargetPlatform.iOS,
            width: width,
          );
          if (amount.isNotEmpty) {
            await tester.enterText(find.byType(TextField).at(0), amount);
            await tester.pumpAndSettle();
          }

          final rect = tester.getRect(find.byType(TextField).at(0));
          expect(rect.center.dx, closeTo(width / 2, 1));
          expect(rect.width, lessThanOrEqualTo(260));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('error text does not overflow at 2.0x on 337dp', (
      tester,
    ) async {
      await _pump(
        tester,
        addExpense,
        platform: TargetPlatform.iOS,
        width: 337,
        textScale: 2,
      );
      await tester.enterText(find.byType(TextField).at(1), 'Dinner');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text(_invalidAmount), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
