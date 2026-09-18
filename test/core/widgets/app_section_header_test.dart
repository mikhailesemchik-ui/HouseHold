import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_section_header.dart';

void main() {
  Widget wrap(Widget child, {TextScaler? textScaler, double width = 360}) {
    return MediaQuery(
      data: MediaQueryData(textScaler: textScaler ?? TextScaler.noScaling),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: width, child: child),
        ),
      ),
    );
  }

  testWidgets('renders label only when there is no trailing action', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AppSectionHeader(label: 'Today')));
    expect(find.text('Today'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('warning variant shows the schedule icon', (tester) async {
    await tester.pumpWidget(
      wrap(const AppSectionHeader(label: 'Overdue', isWarning: true)),
    );
    expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
  });

  testWidgets(
    'long label with a trailing action does not overflow at 2.0x text scale',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          AppSectionHeader(
            label: 'Completed · 128',
            trailing: TextButton(
              onPressed: () {},
              child: const Text('Clear completed'),
            ),
          ),
          textScaler: const TextScaler.linear(2.0),
          width: 320,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Completed · 128'), findsOneWidget);
      expect(find.text('Clear completed'), findsOneWidget);
    },
  );

  testWidgets(
    'label and trailing action both fit on one line when there is room',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          AppSectionHeader(
            label: 'Completed · 2',
            trailing: TextButton(
              onPressed: () {},
              child: const Text('Clear completed'),
            ),
          ),
          width: 600,
        ),
      );
      await tester.pumpAndSettle();

      final labelY = tester.getCenter(find.text('Completed · 2')).dy;
      final buttonY = tester.getCenter(find.text('Clear completed')).dy;
      expect((labelY - buttonY).abs(), lessThan(4));
    },
  );
}
