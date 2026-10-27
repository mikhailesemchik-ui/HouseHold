import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';
import 'package:household_os/features/tasks/domain/task_member.dart';
import 'package:household_os/features/tasks/presentation/task_form_screen.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

typedef _Form = ({String title, String action, Widget screen});

void main() {
  const forms = <_Form>[
    (
      title: 'New expense',
      action: 'Add',
      screen: ExpenseFormScreen(householdId: 'hh'),
    ),
    (
      title: 'Record settlement',
      action: 'Record',
      screen: SettlementFormScreen(householdId: 'hh'),
    ),
    (
      title: 'New task',
      action: 'Create',
      screen: TaskFormScreen(householdId: 'hh'),
    ),
  ];

  // Tests render with the Ahem placeholder font by default, which makes every
  // glyph a full em wide. Load the real Nunito so header widths are the ones
  // users see. The action buttons (TextButton) set their own text style
  // without the theme font, so they fall back to the default family
  // ("Roboto" in tests); give that family the same metrics too.
  setUpAll(() async {
    for (final family in ['Nunito', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in [
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
      ]) {
        final bytes = File('assets/fonts/Nunito-$weight.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  Widget host(Widget screen, double width, double scale) {
    final members = [
      for (var i = 0; i < 2; i++)
        ExpenseMember(userId: 'u$i', displayName: 'Member $i'),
    ];
    return ProviderScope(
      overrides: [
        expenseMembersProvider('hh').overrideWith((ref) async => members),
        currentUserIdProvider.overrideWithValue('u0'),
        taskMembersProvider('hh').overrideWith(
          (ref) async => const [
            TaskMember(userId: 'u1', displayName: 'Alice', publicId: 'a#1'),
          ],
        ),
      ],
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(scale),
        ),
        child: MaterialApp(
          theme: appTheme,
          // Stands in for the platform font the action buttons really use.
          builder: (context, child) => DefaultTextStyle.merge(
            style: const TextStyle(fontFamily: 'Nunito'),
            child: child!,
          ),
          home: screen,
        ),
      ),
    );
  }

  // The title text may contain a line break; match on its words.
  Finder titleFinder(String title) => find.descendant(
    of: find.byType(AppScreenHeader),
    matching: find.byWidgetPredicate(
      (w) => w is Text && w.data?.replaceAll('\n', ' ') == title,
    ),
  );

  for (final form in forms) {
    for (final width in [337.0, 360.0, 414.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('${form.title} header at ${width}dp / ${scale}x: centred, '
            'no collisions', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(host(form.screen, width, scale));
          await tester.pumpAndSettle();

          // Form bodies may overflow under the test font; the header must
          // not be the source.
          final error = tester.takeException();
          if (error != null) {
            expect(error.toString(), isNot(contains('app_screen_header')));
          }
          final title = tester.getRect(titleFinder(form.title));
          final close = tester.getRect(find.byType(AppBackButton));
          final action = tester.getRect(
            find.widgetWithText(TextButton, form.action),
          );

          // Never overlaps the left control or the primary action, which
          // both stay on screen and reachable.
          expect(title.left, greaterThanOrEqualTo(close.right - 0.5));
          expect(title.right, lessThanOrEqualTo(action.left + 0.5));
          expect(action.right, lessThanOrEqualTo(width + 0.5));
          expect(close.left, greaterThanOrEqualTo(0));

          // Exactly centred whenever the action leaves the symmetric area
          // free (otherwise it falls back to the free space between the
          // controls; the real button width is checked on the device).
          const leadingReserve = 84.0;
          final trailingReserve = width - action.left + 12;
          if (trailingReserve <= leadingReserve) {
            expect(title.center.dx, closeTo(width / 2, 1));
          }
        });
      }
    }
  }
}
