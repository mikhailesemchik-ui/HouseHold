import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';

/// Components that replace their text style (AppBar title, SegmentedButton,
/// Chip, SnackBar) lose the ambient family and fall back to SF / Roboto.
void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('shared components resolve to Nunito on $platform', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme.copyWith(platform: platform),
          home: Scaffold(
            appBar: AppBar(title: const Text('Title')),
            body: ListView(
              children: [
                const ListTile(title: Text('Tile'), subtitle: Text('Sub')),
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: const Text('Switch'),
                ),
                const TextField(
                  decoration: InputDecoration(
                    labelText: 'Label',
                    hintText: 'Hint',
                  ),
                ),
                DropdownButton<int>(
                  value: 1,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('Dropdown')),
                  ],
                  onChanged: (_) {},
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Segment')),
                  ],
                  selected: const {1},
                ),
                const Chip(label: Text('Chip')),
                TextButton(onPressed: () {}, child: const Text('Button')),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Nav'),
                NavigationDestination(icon: Icon(Icons.add), label: 'Nav2'),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Typed');
      await tester.pump();

      final wrongFamilies = <String>[];
      for (final element in find.byType(RichText).evaluate()) {
        final paragraph = element.renderObject as RenderParagraph;
        final family = paragraph.text.style?.fontFamily;
        if (family != 'Nunito' && family != 'MaterialIcons') {
          wrongFamilies.add('${paragraph.text.toPlainText()}: $family');
        }
      }
      expect(wrongFamilies, isEmpty);
    });
  }

  test('every TextTheme role resolves to Nunito', () {
    final theme = appTheme.textTheme;
    for (final style in [
      theme.displayLarge,
      theme.headlineMedium,
      theme.headlineSmall,
      theme.titleLarge,
      theme.titleMedium,
      theme.titleSmall,
      theme.bodyLarge,
      theme.bodyMedium,
      theme.bodySmall,
      theme.labelLarge,
      theme.labelMedium,
      theme.labelSmall,
    ]) {
      expect(style?.fontFamily, 'Nunito');
    }
  });

  testWidgets('SnackBar text resolves to Nunito', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Snack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    final paragraph = tester.renderObject<RenderParagraph>(find.text('Snack'));
    expect(paragraph.text.style?.fontFamily, 'Nunito');
  });
}
