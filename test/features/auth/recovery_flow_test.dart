import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_port.dart';

const identity = AuthIdentity(
  userId: 'user-a',
  isAnonymous: false,
  email: 'me@example.test',
  isEmailConfirmed: true,
);

class FakeRecoveryActions implements RecoveryActions {
  final calls = <String>[];
  Object? requestError;
  Object? verifyError;
  Future<void>? requestGate;
  Future<void>? verifyGate;

  @override
  Future<void> requestCode(String email) async {
    calls.add('request:$email');
    await requestGate;
    if (requestError != null) throw requestError!;
  }

  @override
  Future<AuthIdentity> verify(String email, String code) async {
    // The code is deliberately not recorded anywhere.
    calls.add('verify:$email:${code.length}digits');
    await verifyGate;
    if (verifyError != null) throw verifyError!;
    return identity;
  }
}

class _Rig {
  _Rig() {
    container = ProviderContainer(
      overrides: [
        recoveryActionsProvider.overrideWithValue(actions),
        recoveryClockProvider.overrideWithValue(() => now),
      ],
    );
    container.listen(recoveryFlowProvider, (_, _) {}, fireImmediately: true);
  }

  final actions = FakeRecoveryActions();
  DateTime now = DateTime(2026, 1, 1, 12);
  late final ProviderContainer container;

  RecoveryFlowNotifier get flow =>
      container.read(recoveryFlowProvider.notifier);
  RecoveryState get state => container.read(recoveryFlowProvider);
}

Matcher failureIs(EmailAuthFailure f) => isA<RecoveryState>().having(
  (s) => s is RecoveryEmailEntry
      ? s.failure
      : s is RecoveryCodeEntry
      ? s.failure
      : null,
  'failure',
  f,
);

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.container.dispose());

  group('asking for a code', () {
    test('moves to code entry and starts the resend cooldown', () async {
      await rig.flow.requestCode('  me@example.test ');
      final s = rig.state as RecoveryCodeEntry;
      expect(s.email, 'me@example.test');
      expect(s.resendAvailableAt, rig.now.add(recoveryResendCooldown));
      expect(rig.actions.calls, ['request:  me@example.test ']);
    });

    test('a double tap sends one request', () async {
      final gate = Completer<void>();
      rig.actions.requestGate = gate.future;
      final a = rig.flow.requestCode('me@example.test');
      final b = rig.flow.requestCode('me@example.test');
      expect(rig.state, isA<RecoveryRequestingCode>());
      gate.complete();
      await Future.wait([a, b]);
      expect(rig.actions.calls, hasLength(1));
    });

    test('an unknown address looks exactly like a known one', () async {
      // The repository returns normally for "no such account" (otp_disabled);
      // the flow therefore cannot tell, and says "if this belongs to ...".
      await rig.flow.requestCode('nobody@example.test');
      expect(rig.state, isA<RecoveryCodeEntry>());
    });

    test(
      'a network failure keeps the typed address and allows a retry',
      () async {
        rig.actions.requestError = const EmailAuthException(
          EmailAuthFailure.network,
        );
        await rig.flow.requestCode('me@example.test');
        expect(rig.state, failureIs(EmailAuthFailure.network));
        expect((rig.state as RecoveryEmailEntry).email, 'me@example.test');

        rig.actions.requestError = null;
        await rig.flow.requestCode('me@example.test');
        expect(rig.state, isA<RecoveryCodeEntry>());
        expect(rig.actions.calls, hasLength(2));
      },
    );

    test(
      'an invalid address and rate limiting surface as typed failures',
      () async {
        rig.actions.requestError = const EmailAuthException(
          EmailAuthFailure.invalidEmail,
        );
        await rig.flow.requestCode('nope');
        expect(rig.state, failureIs(EmailAuthFailure.invalidEmail));
        rig.actions.requestError = const EmailAuthException(
          EmailAuthFailure.rateLimited,
        );
        await rig.flow.requestCode('me@example.test');
        expect(rig.state, failureIs(EmailAuthFailure.rateLimited));
      },
    );

    test(
      'an unexpected error becomes a generic failure, never raw text',
      () async {
        rig.actions.requestError = StateError('secret server detail 500');
        await rig.flow.requestCode('me@example.test');
        expect(rig.state, failureIs(EmailAuthFailure.serverError));
      },
    );

    test(
      '"I already have a code" skips the request and validates the address',
      () {
        rig.flow.haveCode('not-an-email');
        expect(rig.state, failureIs(EmailAuthFailure.invalidEmail));
        rig.flow.haveCode(' me@example.test ');
        expect(rig.state, isA<RecoveryCodeEntry>());
        expect(rig.actions.calls, isEmpty);
      },
    );

    test(
      'correcting the email returns to step one with it filled in',
      () async {
        await rig.flow.requestCode('me@example.test');
        rig.flow.editEmail();
        final s = rig.state as RecoveryEmailEntry;
        expect(s.email, 'me@example.test');
      },
    );
  });

  group('entering the code', () {
    setUp(() async => rig.flow.requestCode('me@example.test'));

    test('a correct code finishes with the restored identity', () async {
      await rig.flow.verify('123456');
      final s = rig.state as RecoverySucceeded;
      expect(s.identity.userId, 'user-a');
      expect(rig.actions.calls.last, 'verify:me@example.test:6digits');
    });

    test('incorrect and expired codes are recoverable', () async {
      rig.actions.verifyError = const EmailAuthException(
        EmailAuthFailure.codeRejected,
      );
      await rig.flow.verify('000000');
      expect(rig.state, failureIs(EmailAuthFailure.codeRejected));
      await rig.flow.verify('111111'); // expired/reused: same server answer
      expect(rig.state, failureIs(EmailAuthFailure.codeRejected));

      rig.actions.verifyError = null;
      await rig.flow.verify('123456');
      expect(rig.state, isA<RecoverySucceeded>());
    });

    test('a double submit verifies once', () async {
      final gate = Completer<void>();
      rig.actions.verifyGate = gate.future;
      final a = rig.flow.verify('123456');
      final b = rig.flow.verify('123456');
      expect(rig.state, isA<RecoveryVerifying>());
      gate.complete();
      await Future.wait([a, b]);
      expect(
        rig.actions.calls.where((c) => c.startsWith('verify')),
        hasLength(1),
      );
    });

    test(
      'a network failure keeps the user on the code step to retry',
      () async {
        rig.actions.verifyError = const EmailAuthException(
          EmailAuthFailure.network,
        );
        await rig.flow.verify('123456');
        expect(rig.state, failureIs(EmailAuthFailure.network));
        rig.actions.verifyError = null;
        await rig.flow.verify('123456');
        expect(rig.state, isA<RecoverySucceeded>());
      },
    );

    test(
      'the flow disposed mid-verification (scope replaced) is harmless',
      () async {
        final gate = Completer<void>();
        rig.actions.verifyGate = gate.future;
        final pending = rig.flow.verify('123456');
        rig.container.dispose();
        gate.complete();
        await pending;
      },
    );

    test('no state ever holds the code', () async {
      await rig.flow.verify('987654');
      expect(rig.state.toString(), isNot(contains('987654')));
      expect(
        (rig.state as RecoverySucceeded).identity.toString(),
        isNot(contains('987654')),
      );
    });
  });

  group('asking for another code', () {
    setUp(() async => rig.flow.requestCode('me@example.test'));

    test('is refused during the cooldown', () async {
      await rig.flow.resend();
      expect(rig.actions.calls, hasLength(1));
      rig.now = rig.now.add(const Duration(seconds: 59));
      await rig.flow.resend();
      expect(rig.actions.calls, hasLength(1));
    });

    test(
      'works after the cooldown (also after the app was in the background)',
      () async {
        // The cooldown is a timestamp, so a long pause needs no running timer.
        rig.now = rig.now.add(const Duration(minutes: 10));
        await rig.flow.resend();
        expect(rig.actions.calls, hasLength(2));
        final s = rig.state as RecoveryCodeEntry;
        expect(s.resendAvailableAt, rig.now.add(recoveryResendCooldown));
      },
    );

    test('a failed resend stays on the code step with a message', () async {
      rig.now = rig.now.add(const Duration(minutes: 2));
      rig.actions.requestError = const EmailAuthException(
        EmailAuthFailure.rateLimited,
      );
      await rig.flow.resend();
      expect(rig.state, failureIs(EmailAuthFailure.rateLimited));
      expect(rig.state, isA<RecoveryCodeEntry>());
    });
  });

  group('the real actions over the F1 repository', () {
    const target = 'user-target';
    const email = 'me@example.test';

    Future<(ProviderContainer, FakeAuthPort)> build({
      String? signedInAs,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final port = FakeAuthPort(userId: signedInAs)
        ..accounts[email] = target
        ..accountStates[target] = 'active';
      final repo = EmailAccountRepository(port);
      final container = ProviderContainer(
        overrides: [
          emailAccountRepositoryProvider.overrideWithValue(repo),
          sessionSwitchCoordinatorProvider.overrideWith(
            (ref) async => SessionSwitchCoordinator(
              repository: repo,
              marker: SessionSwitchMarker(prefs),
              unregisterPushToken: () async {},
              restorePushRegistration: () async {},
              clearDeviceData: () async {},
              onIdentityChanged: () {},
            ),
          ),
        ],
      );
      container.listen(recoveryFlowProvider, (_, _) {}, fireImmediately: true);
      addTearDown(container.dispose);
      return (container, port);
    }

    test(
      'recovery restores the SAME user id and never signs in anonymously',
      () async {
        final (container, port) = await build();
        final flow = container.read(recoveryFlowProvider.notifier);
        await flow.requestCode(email);
        expect(port.calls, [
          'requestSignInCode:$email',
        ], reason: 'only the existing-account request; nothing else ran');
        await flow.verify(port.signInCode!);
        final s = container.read(recoveryFlowProvider) as RecoverySucceeded;
        expect(s.identity.userId, target);
        expect(port.userId, target);
      },
    );

    test('an unknown email creates nothing and looks the same', () async {
      final (container, port) = await build();
      final flow = container.read(recoveryFlowProvider.notifier);
      await flow.requestCode('nobody@example.test');
      expect(container.read(recoveryFlowProvider), isA<RecoveryCodeEntry>());
      expect(port.userId, isNull);
      expect(port.signInCode, isNull);
      await flow.verify('222222');
      expect(
        container.read(recoveryFlowProvider),
        failureIs(EmailAuthFailure.codeRejected),
      );
      expect(port.userId, isNull);
    });

    test('a wrong code leaves the device signed out', () async {
      final (container, port) = await build();
      final flow = container.read(recoveryFlowProvider.notifier);
      await flow.requestCode(email);
      await flow.verify('000000');
      expect(
        container.read(recoveryFlowProvider),
        failureIs(EmailAuthFailure.codeRejected),
      );
      expect(port.userId, isNull);
    });

    test('over an unlinked anonymous account the switch is refused', () async {
      final (container, port) = await build(signedInAs: 'user-anon');
      final flow = container.read(recoveryFlowProvider.notifier);
      await flow.requestCode(email);
      await flow.verify(port.signInCode!);
      expect(
        container.read(recoveryFlowProvider),
        failureIs(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(
        port.userId,
        'user-anon',
        reason: 'the guest account is untouched',
      );
    });

    test('a deleting account is refused after the code is checked', () async {
      final (container, port) = await build();
      port.accountStates[target] = 'deleting';
      final flow = container.read(recoveryFlowProvider.notifier);
      await flow.requestCode(email);
      await flow.verify(port.signInCode!);
      expect(
        container.read(recoveryFlowProvider),
        failureIs(EmailAuthFailure.accountNotActive),
      );
      expect(port.userId, isNull);
    });
  });
}
