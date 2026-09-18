import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/profile/presentation/profile_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Wraps the screen in a stand-in for the app shell — the same
  /// `Scaffold(extendBody: true)` + bottom navigation arrangement — because
  /// that is what publishes the nav bar's measured height to descendants as
  /// `MediaQuery.padding.bottom`.
  Widget buildProfileScreen({
    required double safeAreaBottom,
    double navBarHeight = 64,
    String? avatarUrl,
    String displayName = 'Alice',
    String publicId = 'alice#1234',
    Size size = const Size(400, 800),
    double textScale = 1.0,
  }) {
    return ProviderScope(
      overrides: [
        currentProfileProvider.overrideWith(
          (ref) async => Profile(
            userId: 'user-1',
            publicId: publicId,
            displayName: displayName,
            createdAt: DateTime.utc(2026, 8, 1),
            avatarUrl: avatarUrl,
          ),
        ),
      ],
      child: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: EdgeInsets.only(bottom: safeAreaBottom),
          textScaler: TextScaler.linear(textScale),
        ),
        child: MaterialApp(
          theme: appTheme,
          home: Scaffold(
            extendBody: true,
            bottomNavigationBar: SizedBox(height: navBarHeight),
            body: const ProfileScreen(),
          ),
        ),
      ),
    );
  }

  double bottomPaddingOfList(WidgetTester tester) {
    final sliverPadding = tester.widget<SliverPadding>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(SliverPadding),
          )
          .first,
    );
    return (sliverPadding.padding as EdgeInsets).bottom;
  }

  group('ProfileScreen bottom-nav clearance', () {
    testWidgets(
      'clears the shell navigation exactly once below the final settings row',
      (tester) async {
        const navBarHeight = 64.0;
        await tester.pumpWidget(
          buildProfileScreen(safeAreaBottom: 24, navBarHeight: navBarHeight),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('Show task names'), 300);
        expect(find.text('Show task names'), findsOneWidget);

        // The shell publishes the nav bar's measured height as
        // MediaQuery.padding.bottom, and this list consumes it automatically
        // by not declaring its own padding. Reserving exactly that much means
        // the last row clears the nav bar without the screen re-adding a
        // hand-maintained nav height on top of it — the double count this
        // replaced reserved roughly twice this space.
        expect(bottomPaddingOfList(tester), navBarHeight);
      },
    );

    testWidgets('supporting copy for the final row does not overflow', (
      tester,
    ) async {
      await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Display task names on the home-screen widget'),
        300,
      );
      expect(
        find.text('Display task names on the home-screen widget'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ProfileScreen identity', () {
    testWidgets('renders display name and public ID', (tester) async {
      await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('alice#1234'), findsOneWidget);
    });

    testWidgets(
      'avatar edit button has a real touch target and semantic label',
      (tester) async {
        await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
        await tester.pumpAndSettle();

        final iconButton = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.edit_rounded),
            matching: find.byType(IconButton),
          ),
        );
        expect(iconButton.tooltip, 'Edit profile photo');

        final size = tester.getSize(
          find.ancestor(
            of: find.byIcon(Icons.edit_rounded),
            matching: find.byType(IconButton),
          ),
        );
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets('public ID copy has a real touch target and semantic label', (
      tester,
    ) async {
      await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
      await tester.pumpAndSettle();

      final copyButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.copy_rounded),
      );
      expect(copyButton.tooltip, 'Copy ID');

      final size = tester.getSize(
        find.widgetWithIcon(IconButton, Icons.copy_rounded),
      );
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('copying the public ID gives visible feedback', (tester) async {
      await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithIcon(IconButton, Icons.copy_rounded));
      await tester.pumpAndSettle();

      expect(find.text('ID copied to clipboard.'), findsOneWidget);
    });

    testWidgets('long display name renders without overflow', (tester) async {
      await tester.pumpWidget(
        buildProfileScreen(
          safeAreaBottom: 0,
          displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2.0x text scale without overflow', (tester) async {
      await tester.pumpWidget(
        buildProfileScreen(
          safeAreaBottom: 0,
          size: const Size(360, 800),
          textScale: 2.0,
          displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'settings rows do not overflow at 2.0x (dense + two-line subtitle '
      'regression)',
      (tester) async {
        await tester.pumpWidget(
          buildProfileScreen(
            safeAreaBottom: 0,
            size: const Size(360, 800),
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Task reminders'), findsOneWidget);
        expect(find.text('Household updates'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Show task names'), 300);
        expect(find.text('Show task names'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('display-name edit dialog preserves input on failure', (
      tester,
    ) async {
      await tester.pumpWidget(buildProfileScreen(safeAreaBottom: 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New Name');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // No Supabase client is initialized in this test, so the update
      // fails — the name shown must remain the last-known-good value (the
      // dialog does not optimistically rename before the write succeeds).
      expect(find.text('Could not update name. Try again.'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
    });
  });

  group('ProfileScreen avatar removal', () {
    testWidgets('asks for confirmation before removing the photo', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildProfileScreen(
          safeAreaBottom: 0,
          avatarUrl: 'https://example.com/avatar.jpg',
        ),
      );
      await tester.pumpAndSettle();
      // The test binding always fails a fetch for this fake URL, and the
      // avatar-edit button's ripple animation can pump several more frames
      // that each retry the same doomed fetch; none of that is what this
      // test is about, so drain every queued exception rather than let one
      // leftover fail the test.
      while (tester.takeException() != null) {}

      await tester.tap(find.byIcon(Icons.edit_rounded));
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}
      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}

      // Names the action — never a generic "OK" — and the removal has not
      // been confirmed yet, so the (unavailable-in-test) repository call
      // never fires.
      expect(find.text('Remove photo?'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Remove'), findsOneWidget);
    });
  });
}
