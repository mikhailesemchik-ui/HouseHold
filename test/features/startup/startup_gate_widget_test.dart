import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/startup/presentation/startup_provider.dart';
import 'package:household_os/features/startup/presentation/startup_screen.dart';

import 'fake_startup_port.dart';

Widget _app(FakeStartupPort port) {
  final router = GoRouter(
    initialLocation: '/startup',
    routes: [
      GoRoute(path: '/startup', builder: (_, _) => const StartupScreen()),
      GoRoute(path: '/recover', builder: (_, _) => const Text('RECOVERY')),
    ],
  );
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [startupPortProvider.overrideWithValue(port)],
    child: MaterialApp.router(theme: appTheme, routerConfig: router),
  );
}

void main() {
  testWidgets('no session: the welcome choice shows and nothing is created', (
    tester,
  ) async {
    final port = FakeStartupPort(hasSession: false);
    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();

    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('I already have an account'), findsOneWidget);
    expect(port.calls, isNot(contains('signInAnonymously')));
  });

  testWidgets('a restored session never flashes the welcome screen', (
    tester,
  ) async {
    final load = Completer<void>();
    final port = FakeStartupPort(
      onLoad: () async {
        await load.future;
        return fakeStartupProfile();
      },
    );
    await tester.pumpWidget(_app(port));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Get started'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    }
    load.complete();
    await tester.pump();
    expect(find.text('Get started'), findsNothing);
  });

  testWidgets('Get started: one sign-in even if tapped twice, buttons lock', (
    tester,
  ) async {
    final gate = Completer<void>();
    final port = FakeStartupPort(
      hasSession: false,
      onSignIn: () => gate.future,
    );
    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get started'));
    await tester.pump();
    // The welcome view is replaced by the loading frame, so a second tap has
    // nothing to hit; the notifier would ignore it anyway.
    expect(find.text('Get started'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    // The loading frame spins until the app takes over, so pump, don't settle.
    await tester.pump();
    await tester.pump();
    expect(port.calls.where((c) => c == 'signInAnonymously'), hasLength(1));
  });

  testWidgets('I already have an account opens recovery without creating a '
      'guest account', (tester) async {
    final port = FakeStartupPort(hasSession: false);
    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('I already have an account'));
    await tester.pumpAndSettle();
    expect(find.text('RECOVERY'), findsOneWidget);
    expect(port.calls, isNot(contains('signInAnonymously')));
  });

  testWidgets('a failed anonymous sign-in shows a retry that returns to the '
      'choice', (tester) async {
    final port = FakeStartupPort(
      hasSession: false,
      signInError: StateError('boom'),
    );
    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing, reason: 'no raw errors');
    port.signInError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('welcome fits a small screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 480),
          textScaler: TextScaler.linear(1.8),
        ),
        child: _app(FakeStartupPort(hasSession: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Get started'), findsOneWidget);
  });
}
