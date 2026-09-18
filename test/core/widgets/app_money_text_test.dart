import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_money_text.dart';

void main() {
  testWidgets('renders exactly the formatted string it was given', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppMoneyText('€25.50'))),
    );

    expect(find.text('€25.50'), findsOneWidget);
  });

  testWidgets('applies tabular figures', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppMoneyText('€25.50'))),
    );

    final text = tester.widget<Text>(find.text('€25.50'));
    expect(
      text.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets(
    'preserves a caller-supplied style while adding tabular figures',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppMoneyText(
              '€25.50',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('€25.50'));
      expect(text.style?.fontWeight, FontWeight.w600);
      expect(
        text.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    },
  );
}
