import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/routing/app_router.dart';

/// Guards the Root-Only Bottom Navigation contract: the floating bottom nav
/// is visible only on the shell's three root destinations, and every deeper
/// route hides it without leaving a phantom nav-sized gap.
void main() {
  group('isShellRootPath', () {
    test('the three shell roots are root routes', () {
      expect(isShellRootPath('/today'), isTrue);
      expect(isShellRootPath('/homes'), isTrue);
      expect(isShellRootPath('/profile'), isTrue);
    });

    test('nested household routes are not root routes', () {
      expect(isShellRootPath('/homes/abc'), isFalse);
      expect(isShellRootPath('/homes/abc/tasks'), isFalse);
      expect(isShellRootPath('/homes/abc/shopping'), isFalse);
      expect(isShellRootPath('/homes/abc/expenses'), isFalse);
      expect(isShellRootPath('/homes/abc/members'), isFalse);
      expect(isShellRootPath('/homes/abc/statistics'), isFalse);
      expect(isShellRootPath('/homes/abc/activity'), isFalse);
    });

    test('routes outside the shell are not root routes', () {
      expect(isShellRootPath('/startup'), isFalse);
    });
  });

  group('shell nav-clearance mechanics (mirrors _ShellScaffold wiring)', () {
    // Reproduces the real nesting from `shell_geometry_test.dart`: an outer
    // shell Scaffold (extendBody + bottomNavigationBar) around a feature
    // body, with the nav bar present or absent exactly as `_ShellScaffold`
    // decides via `showNav`.
    const navBarHeight = 64.0;
    const deviceInset = 24.0;

    Widget buildShell({
      required bool showNav,
      required void Function(BuildContext) probe,
    }) {
      return MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(bottom: deviceInset),
        ),
        child: MaterialApp(
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: showNav
                ? const SizedBox(height: navBarHeight)
                : null,
            body: Builder(
              builder: (context) {
                probe(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }

    testWidgets('root route: clearance equals the nav bar height', (
      tester,
    ) async {
      late EdgeInsets padding;
      await tester.pumpWidget(
        buildShell(
          showNav: true,
          probe: (context) => padding = MediaQuery.paddingOf(context),
        ),
      );

      expect(padding.bottom, navBarHeight);
    });

    testWidgets(
      'nested route: clearance falls back to the device safe area, not a phantom gap',
      (tester) async {
        late EdgeInsets padding;
        await tester.pumpWidget(
          buildShell(
            showNav: false,
            probe: (context) => padding = MediaQuery.paddingOf(context),
          ),
        );

        // Not zero, and not the nav bar's height either — exactly the plain
        // device safe area, matching what a screen outside the shell sees.
        expect(padding.bottom, deviceInset);
      },
    );
  });
}
