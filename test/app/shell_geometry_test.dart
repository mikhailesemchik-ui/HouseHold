import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the Phase A layout contract: the shell — not each feature screen —
/// owns keyboard resizing and publishes the bottom-navigation clearance.
///
/// These tests pin the Flutter framework behaviour the whole app depends on,
/// so a framework upgrade that changed it would fail here rather than silently
/// re-open the class of bugs this contract was written to close.
void main() {
  const navBarHeight = 64.0;
  const deviceInset = 24.0;
  const keyboardHeight = 300.0;

  /// Reproduces the real nesting: shell Scaffold (extendBody + bottom nav)
  /// wrapping a feature Scaffold that has an AppBar and no bottom nav.
  Widget buildShell({
    required double bottomViewInset,
    required void Function(BuildContext) probe,
    Widget? featureBody,
  }) {
    return MediaQuery(
      data: MediaQueryData(
        padding: const EdgeInsets.only(bottom: deviceInset),
        viewPadding: const EdgeInsets.only(bottom: deviceInset),
        viewInsets: EdgeInsets.only(bottom: bottomViewInset),
      ),
      child: MaterialApp(
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: const SizedBox(height: navBarHeight),
          body: Scaffold(
            appBar: AppBar(title: const Text('Feature')),
            body: Builder(
              builder: (context) {
                probe(context);
                return featureBody ??
                    ListView(children: const [SizedBox(height: 50)]);
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'shell publishes the measured nav height to feature screens as padding',
    (tester) async {
      late EdgeInsets padding;
      await tester.pumpWidget(
        buildShell(
          bottomViewInset: 0,
          probe: (context) => padding = MediaQuery.paddingOf(context),
        ),
      );

      // This is the value `context.shellBottomInset` returns, and the reason
      // feature screens must never add a nav-height constant on top of it.
      expect(padding.bottom, navBarHeight);
    },
  );

  testWidgets('a feature ListView consumes that padding automatically', (
    tester,
  ) async {
    await tester.pumpWidget(buildShell(bottomViewInset: 0, probe: (_) {}));

    final sliverPadding = tester.widget<SliverPadding>(
      find.byType(SliverPadding).first,
    );
    expect((sliverPadding.padding as EdgeInsets).bottom, navBarHeight);
  });

  testWidgets('the shell consumes the keyboard inset for feature screens', (
    tester,
  ) async {
    late double viewInsetBottom;
    await tester.pumpWidget(
      buildShell(
        bottomViewInset: keyboardHeight,
        probe: (context) =>
            viewInsetBottom = MediaQuery.viewInsetsOf(context).bottom,
      ),
    );

    // Feature screens are structurally blind to the keyboard: the shell's
    // Scaffold strips the inset for everything in its body. This is why a
    // feature must use focus state, never `viewInsets`, to know whether its
    // own field raised the keyboard.
    expect(viewInsetBottom, 0);
  });

  testWidgets('nav clearance drops to zero while the keyboard is open', (
    tester,
  ) async {
    late EdgeInsets padding;
    await tester.pumpWidget(
      buildShell(
        bottomViewInset: keyboardHeight,
        probe: (context) => padding = MediaQuery.paddingOf(context),
      ),
    );

    // The feature viewport has already been resized above the keyboard, so no
    // further bottom clearance is owed. Screens that simply read this value
    // therefore stay correct in both states with no branching of their own.
    expect(padding.bottom, 0);
  });
}
