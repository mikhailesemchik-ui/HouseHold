import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';

void main() {
  Widget wrap(Widget child, {TextScaler? textScaler, Size? size}) {
    return MediaQuery(
      data: MediaQueryData(
        size: size ?? const Size(400, 800),
        textScaler: textScaler ?? TextScaler.noScaling,
      ),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('renders a row per requested section count', (tester) async {
    await tester.pumpWidget(
      wrap(const AppSkeletonList(sectionCounts: {'Today': 2, 'Upcoming': 1})),
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
  });

  testWidgets('omits the label for the flat-list section key', (tester) async {
    await tester.pumpWidget(
      wrap(const AppSkeletonList(sectionCounts: {'': 3})),
    );

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('scrolls instead of clipping on a short viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AppSkeletonList(sectionCounts: {'Today': 8, 'Upcoming': 8}),
        size: const Size(360, 300),
        textScaler: const TextScaler.linear(2.0),
      ),
    );

    // Previously a ListView with NeverScrollableScrollPhysics, which silently
    // clipped whatever did not fit.
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Upcoming'), 100);
    expect(find.text('Upcoming'), findsOneWidget);
  });

  testWidgets('owns no scrollable when embedded in a host that scrolls', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        ListView(
          children: const [
            AppSkeletonList(sectionCounts: {'Today': 2}, scrollable: false),
          ],
        ),
      ),
    );

    // Exactly one scroll view: the host's. Nesting a second one is the
    // failure this flag exists to prevent.
    expect(find.byType(Scrollable), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
