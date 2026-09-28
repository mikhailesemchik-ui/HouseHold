import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';

Widget _header({required String title, bool centerTitle = true}) => MaterialApp(
  home: Scaffold(
    body: AppScreenHeader(
      leading: const Center(child: SizedBox(width: 48, height: 48)),
      title: title,
      centerTitle: centerTitle,
      actions: const [SizedBox(width: 48, height: 48)],
    ),
  ),
);

void main() {
  testWidgets('centerTitle centers the title on the header width', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'Home'));
    final title = tester.getCenter(find.text('Home')).dx;
    expect(
      title,
      closeTo(tester.getSize(find.byType(AppScreenHeader)).width / 2, 0.5),
    );
  });

  testWidgets('without centerTitle the title stays left-aligned', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'Home', centerTitle: false));
    expect(tester.getTopLeft(find.text('Home')).dx, closeTo(76, 0.5));
  });

  testWidgets('a long centered title ellipsizes without touching controls', (
    tester,
  ) async {
    await tester.pumpWidget(_header(title: 'A very long household name ' * 4));
    final box = tester.getRect(find.byType(Text));
    final width = tester.getSize(find.byType(AppScreenHeader)).width;
    expect(box.left, greaterThanOrEqualTo(64));
    expect(box.right, lessThanOrEqualTo(width - 64));
  });
}
