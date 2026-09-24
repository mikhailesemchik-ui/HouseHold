import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/app.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/startup/presentation/startup_screen.dart';

Profile _fakeProfile() => Profile(
  userId: 'uid-1',
  publicId: 'ABCD-1234',
  displayName: 'User-ABCD',
  createdAt: DateTime(2026),
);

void main() {
  group('startupFriendlyErrorMessage', () {
    test('returns network message for SocketException', () {
      final err = const SocketException('Failed host lookup');
      expect(startupFriendlyErrorMessage(err), contains("Couldn't connect"));
    });

    test('returns network message when error contains ClientException', () {
      final err = Exception(
        'ClientException with SocketException: Failed host lookup',
      );
      expect(startupFriendlyErrorMessage(err), contains("Couldn't connect"));
    });

    test(
      'returns network message when error contains SocketException text',
      () {
        final err = Exception('SocketException: Connection refused');
        expect(startupFriendlyErrorMessage(err), contains("Couldn't connect"));
      },
    );

    test('returns network message when error contains Failed host lookup', () {
      final err = Exception('Failed host lookup: example.supabase.co');
      expect(startupFriendlyErrorMessage(err), contains("Couldn't connect"));
    });

    test('returns generic message for unexpected errors', () {
      final err = StateError('Auth failed unexpectedly');
      expect(
        startupFriendlyErrorMessage(err),
        contains('Something went wrong'),
      );
    });

    test('returns generic message for unknown exception types', () {
      expect(
        startupFriendlyErrorMessage(Exception('some other error')),
        contains('Something went wrong'),
      );
    });
  });

  group('StartupScreen widget', () {
    testWidgets('shows loading indicator while profile is loading', (
      tester,
    ) async {
      final completer = Completer<Profile>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith((ref) => completer.future),
          ],
          child: const MaterialApp(home: StartupScreen()),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('loading frame shows the app identity, not a bare spinner', (
      tester,
    ) async {
      final completer = Completer<Profile>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith((ref) => completer.future),
          ],
          child: const MaterialApp(home: StartupScreen()),
        ),
      );
      expect(find.text('Household OS'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('error frame keeps the app identity alongside retry', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith(
              (ref) async => throw Exception('SocketException: nope'),
            ),
          ],
          child: const MaterialApp(home: StartupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Household OS'), findsOneWidget);
      expect(find.textContaining("Couldn't connect"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });

    testWidgets('startup screen shows no email or password fields', (
      tester,
    ) async {
      final completer = Completer<Profile>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith((ref) => completer.future),
          ],
          child: const MaterialApp(home: StartupScreen()),
        ),
      );
      // No email/password auth gate on startup
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Sign in'), findsNothing);
      expect(find.text('Sign up'), findsNothing);
    });

    testWidgets('shows loading (not login) while profile resolves', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentProfileProvider.overrideWith((ref) async => _fakeProfile()),
          ],
          child: const MaterialApp(home: StartupScreen()),
        ),
      );
      // Still shows loading before navigation fires (not a login screen)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  // RR-001: Riverpod 3 retries failed providers ~10 times with backoff while
  // reporting "loading", so offline the startup screen sat on a spinner for
  // minutes. With the app's retry policy the error frame (with Retry) shows
  // as soon as the load fails.
  group('provider retry policy (RR-001)', () {
    Widget app({required bool retryDisabled}) => ProviderScope(
      retry: retryDisabled ? noProviderRetry : null,
      overrides: [
        currentProfileProvider.overrideWith(
          (ref) => Future<Profile>.error(const SocketException('offline')),
        ),
      ],
      child: const MaterialApp(home: StartupScreen()),
    );

    testWidgets('failed startup load shows the error frame immediately', (
      tester,
    ) async {
      await tester.pumpWidget(app(retryDisabled: true));
      await tester.pump();
      await tester.pump();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining("Couldn't connect"), findsOneWidget);
    });

    testWidgets('default retry keeps a failed load on the spinner', (
      tester,
    ) async {
      await tester.pumpWidget(app(retryDisabled: false));
      await tester.pump();
      await tester.pump();

      expect(find.text('Retry'), findsNothing);
      // Drain pending retry timers so the test can end cleanly.
      await tester.pump(const Duration(minutes: 5));
    });
  });
}
