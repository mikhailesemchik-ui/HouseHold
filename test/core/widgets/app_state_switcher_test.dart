import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_state_switcher.dart';

Widget _host(TargetPlatform platform, String key) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: AppStateSwitcher(stateKey: key, child: const Text('header')),
);

void main() {
  testWidgets('android cross-fades out of loading, so two headers coexist', (
    tester,
  ) async {
    await tester.pumpWidget(_host(TargetPlatform.android, 'loading'));
    await tester.pumpWidget(_host(TargetPlatform.android, 'data'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('header'), findsNWidgets(2));
    await tester.pumpAndSettle();
    expect(find.text('header'), findsOneWidget);
  });

  testWidgets('ios swaps out of loading instantly, never doubling a header', (
    tester,
  ) async {
    await tester.pumpWidget(_host(TargetPlatform.iOS, 'loading'));
    await tester.pumpWidget(_host(TargetPlatform.iOS, 'data'));
    await tester.pump();
    expect(find.text('header'), findsOneWidget);
  });

  testWidgets('ios still animates other state changes', (tester) async {
    await tester.pumpWidget(_host(TargetPlatform.iOS, 'data'));
    await tester.pumpWidget(_host(TargetPlatform.iOS, 'empty'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('header'), findsNWidgets(2));
    await tester.pumpAndSettle();
  });
}
