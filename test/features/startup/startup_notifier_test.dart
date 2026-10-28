import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/startup/domain/startup_state.dart';
import 'package:household_os/features/startup/presentation/startup_provider.dart';

import 'fake_startup_port.dart';

class _Run {
  _Run(this.port) {
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [startupPortProvider.overrideWithValue(port)],
    );
    container.listen(
      startupProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
  }

  final FakeStartupPort port;
  late final ProviderContainer container;
  final states = <StartupState>[];

  StartupNotifier get notifier => container.read(startupProvider.notifier);
  StartupState get state => container.read(startupProvider);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void dispose() => container.dispose();
}

void main() {
  group('with a restored session', () {
    test(
      'goes straight to the app: no welcome, no sign-in, no sign-out',
      () async {
        final run = _Run(FakeStartupPort(hasSession: true));
        addTearDown(run.dispose);
        await run.settle();
        await run.settle();
        expect(run.state, isA<StartupReady>());
        expect(run.states.whereType<StartupWelcome>(), isEmpty);
        expect(run.port.calls, [
          'resumePendingCleanup',
          'loadProfile',
          'syncPush:uid-1',
        ]);
        expect(run.port.hasSession, isTrue);
      },
    );

    test(
      'offline: keeps the session, shows a retryable error, then recovers',
      () async {
        var online = false;
        final port = FakeStartupPort(
          onLoad: () async => online
              ? fakeStartupProfile()
              : throw const SocketException('offline'),
        );
        final run = _Run(port);
        addTearDown(run.dispose);
        await run.settle();
        await run.settle();
        expect(run.state, isA<StartupFailed>());
        expect(port.hasSession, isTrue);
        expect(port.calls, isNot(contains('signInAnonymously')));

        online = true;
        await run.notifier.retry();
        expect(run.state, isA<StartupReady>());
        expect(port.calls, isNot(contains('signInAnonymously')));
      },
    );

    test('a failed cleanup does not block an existing session', () async {
      final run = _Run(FakeStartupPort(cleanupError: StateError('prefs')));
      addTearDown(run.dispose);
      await run.settle();
      await run.settle();
      expect(run.state, isA<StartupReady>());
    });
  });

  group('without a session', () {
    test('shows the welcome choice and creates nothing', () async {
      final run = _Run(FakeStartupPort(hasSession: false));
      addTearDown(run.dispose);
      await run.settle();
      expect(run.state, isA<StartupWelcome>());
      expect(run.port.calls, ['resumePendingCleanup']);
    });

    test(
      'pending cleanup finishes BEFORE the welcome choice is offered',
      () async {
        final gate = Completer<void>();
        final port = FakeStartupPort(
          hasSession: false,
          onResume: () => gate.future,
        );
        final run = _Run(port);
        addTearDown(run.dispose);
        await run.settle();
        expect(run.state, isA<StartupResolving>(), reason: 'no welcome yet');
        gate.complete();
        await run.settle();
        expect(run.state, isA<StartupWelcome>());
      },
    );

    test('a cleanup that ends the session is respected', () async {
      final port = FakeStartupPort(hasSession: true);
      port.onResume = () async => port.hasSession = false; // deletion finished
      final run = _Run(port);
      addTearDown(run.dispose);
      await run.settle();
      expect(run.state, isA<StartupWelcome>());
      expect(port.calls, isNot(contains('loadProfile')));
    });

    test(
      'Get started signs in anonymously exactly once, even on a double tap',
      () async {
        final gate = Completer<void>();
        final port = FakeStartupPort(
          hasSession: false,
          onSignIn: () => gate.future,
        );
        final run = _Run(port);
        addTearDown(run.dispose);
        await run.settle();

        final first = run.notifier.continueWithoutRegistration();
        final second = run.notifier.continueWithoutRegistration();
        expect(run.state, isA<StartupSigningIn>());
        gate.complete();
        await Future.wait([first, second]);
        expect(port.calls.where((c) => c == 'signInAnonymously'), hasLength(1));
        expect(run.state, isA<StartupReady>());
      },
    );

    test(
      'the anonymous branch is unreachable outside the welcome state',
      () async {
        final run = _Run(FakeStartupPort(hasSession: true));
        addTearDown(run.dispose);
        await run.settle();
        await run.settle();
        await run.notifier.continueWithoutRegistration();
        expect(run.port.calls, isNot(contains('signInAnonymously')));
      },
    );

    test('a cleanup that cannot finish blocks anonymous creation', () async {
      final port = FakeStartupPort(
        hasSession: false,
        cleanupError: StateError('still pending'),
      );
      final run = _Run(port);
      addTearDown(run.dispose);
      await run.settle();
      expect(run.state, isA<StartupWelcome>());
      await run.notifier.continueWithoutRegistration();
      expect(run.state, isA<StartupFailed>());
      expect(port.calls, isNot(contains('signInAnonymously')));
    });

    test('a session that appears meanwhile is never replaced', () async {
      final port = FakeStartupPort(hasSession: false);
      final run = _Run(port);
      addTearDown(run.dispose);
      await run.settle();
      port.hasSession = true;
      await run.notifier.continueWithoutRegistration();
      expect(port.calls, isNot(contains('signInAnonymously')));
      expect(run.state, isA<StartupReady>());
    });

    test('a failed sign-in is recoverable and returns to welcome', () async {
      final port = FakeStartupPort(
        hasSession: false,
        signInError: const SocketException('offline'),
      );
      final run = _Run(port);
      addTearDown(run.dispose);
      await run.settle();
      await run.notifier.continueWithoutRegistration();
      expect(run.state, isA<StartupFailed>());
      port.signInError = null;
      await run.notifier.retry();
      expect(run.state, isA<StartupWelcome>());
      await run.notifier.continueWithoutRegistration();
      expect(run.state, isA<StartupReady>());
    });

    test('the scope being replaced mid sign-in is harmless', () async {
      final gate = Completer<void>();
      final port = FakeStartupPort(
        hasSession: false,
        onSignIn: () => gate.future,
      );
      final run = _Run(port);
      await run.settle();
      final pending = run.notifier.continueWithoutRegistration();
      run.dispose(); // the user-scoped root swaps the scope on sign-in
      gate.complete();
      await pending; // must not throw or touch disposed state
      expect(port.calls.where((c) => c == 'loadProfile'), isEmpty);
    });
  });

  group('push registration at startup', () {
    test('runs once after the profile loads, for that user only', () async {
      final run = _Run(FakeStartupPort());
      addTearDown(run.dispose);
      await run.settle();
      await run.settle();
      expect(run.port.calls.where((c) => c.startsWith('syncPush')), [
        'syncPush:uid-1',
      ]);
    });

    test(
      'never runs without a session, on a load failure, or on welcome',
      () async {
        final welcome = _Run(FakeStartupPort(hasSession: false));
        addTearDown(welcome.dispose);
        await welcome.settle();
        expect(
          welcome.port.calls.where((c) => c.startsWith('syncPush')),
          isEmpty,
        );

        final failed = _Run(
          FakeStartupPort(onLoad: () async => throw const SocketException('x')),
        );
        addTearDown(failed.dispose);
        await failed.settle();
        await failed.settle();
        expect(
          failed.port.calls.where((c) => c.startsWith('syncPush')),
          isEmpty,
        );
      },
    );

    test('never runs for an account that is being deleted', () async {
      final run = _Run(
        FakeStartupPort(
          onLoad: () async => Profile(
            userId: 'uid-1',
            publicId: 'P',
            displayName: 'N',
            createdAt: DateTime(2026),
            accountState: 'deleting',
          ),
        ),
      );
      addTearDown(run.dispose);
      await run.settle();
      await run.settle();
      expect(run.state, isA<StartupReady>());
      expect(run.port.calls.where((c) => c.startsWith('syncPush')), isEmpty);
    });

    test('a failing registration never delays or fails startup', () async {
      final port = FakeStartupPort()
        ..syncError = const SocketException('offline');
      final run = _Run(port);
      addTearDown(run.dispose);
      await run.settle();
      await run.settle();
      await run.settle();
      expect(run.state, isA<StartupReady>());
    });
  });
}
