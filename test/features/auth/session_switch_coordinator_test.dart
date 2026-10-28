import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_port.dart';

const _old = 'user-old';
const _target = 'user-target';
const _email = 'target@example.test';

Matcher failsWith(EmailAuthFailure failure) => throwsA(
  isA<EmailAuthException>().having((e) => e.failure, 'failure', failure),
);

class _Rig {
  _Rig(this.port, this.prefs) {
    coordinator = SessionSwitchCoordinator(
      repository: EmailAccountRepository(port),
      marker: SessionSwitchMarker(prefs),
      unregisterPushToken: () async {
        events.add('unregisterPushToken(session=${port.userId})');
        if (failPush) throw StateError('push failure');
      },
      restorePushRegistration: () async {
        events.add('restorePushRegistration');
        if (failRestore) throw StateError('restore failure');
      },
      clearDeviceData: () async {
        events.add('clearDeviceData');
        if (failCleanup) throw StateError('cleanup failure');
      },
      onIdentityChanged: () => events.add('identityChanged'),
    );
  }

  final FakeAuthPort port;
  final SharedPreferences prefs;
  late final SessionSwitchCoordinator coordinator;
  final events = <String>[];
  bool failPush = false;
  bool failRestore = false;
  bool failCleanup = false;

  SessionSwitchMarker get marker => SessionSwitchMarker(prefs);

  Future<void> requestCode() async {
    await EmailAccountRepository(port).sendRecoveryCode(_email);
  }
}

Future<_Rig> _rig({
  String? signedInAs,
  bool linked = false,
  String targetState = 'active',
}) async {
  SharedPreferences.setMockInitialValues({
    'pending_financial_op/expense/$_old/hh-1': '[{"id":"o1","hash":"h1"}]',
    'pending_financial_op/expense/$_target/hh-1': '[{"id":"t1","hash":"h2"}]',
    'reminder_enabled': true,
    'widget_privacy_mode': 'show_names',
    'account_deletion_attempt_user': 'user-being-deleted',
  });
  final prefs = await SharedPreferences.getInstance();
  final port = FakeAuthPort(
    userId: signedInAs,
    anonymous: !linked,
    email: linked ? 'old@example.test' : null,
  );
  port.accounts[_email] = _target;
  port.accountStates[_target] = targetState;
  return _Rig(port, prefs);
}

void main() {
  group('switching accounts', () {
    test(
      'a fresh device recovers without any previous user to clean up',
      () async {
        final rig = await _rig();
        await rig.requestCode();
        final identity = await rig.coordinator.recover(
          email: _email,
          code: rig.port.signInCode!,
        );
        expect(identity.userId, _target);
        expect(rig.port.userId, _target);
        expect(rig.events, ['identityChanged', 'clearDeviceData']);
        expect(rig.marker.previousUserId, isNull);
      },
    );

    test('an unlinked anonymous account is never replaced silently', () async {
      final rig = await _rig(signedInAs: _old);
      await rig.requestCode();
      await expectLater(
        rig.coordinator.recover(email: _email, code: rig.port.signInCode!),
        failsWith(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(rig.port.userId, _old);
      expect(rig.events, isEmpty, reason: 'nothing was touched');
      expect(rig.marker.previousUserId, isNull);
      expect(rig.port.calls.where((c) => c == 'verifySignInCode'), isEmpty);
    });

    test(
      'with acknowledgement the previous user is cleaned up around the switch',
      () async {
        final rig = await _rig(signedInAs: _old);
        await rig.requestCode();
        await rig.coordinator.recover(
          email: _email,
          code: rig.port.signInCode!,
          acknowledgeAnonymousLoss: true,
        );
        expect(rig.events, [
          'unregisterPushToken(session=$_old)',
          'identityChanged',
          'clearDeviceData',
        ]);
        expect(rig.port.userId, _target);
        expect(rig.marker.previousUserId, isNull);
      },
    );

    test('a linked user can switch without acknowledgement', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.requestCode();
      final identity = await rig.coordinator.recover(
        email: _email,
        code: rig.port.signInCode!,
      );
      expect(identity.userId, _target);
    });

    test('a wrong code changes and cleans nothing', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.requestCode();
      await expectLater(
        rig.coordinator.recover(email: _email, code: '000000'),
        failsWith(EmailAuthFailure.codeRejected),
      );
      expect(rig.port.userId, _old);
      expect(rig.events, [
        'unregisterPushToken(session=$_old)',
        'restorePushRegistration',
      ]);
      expect(rig.marker.previousUserId, isNull);
    });

    test(
      'a deleting account ends signed out, with the device cleaned',
      () async {
        final rig = await _rig(
          signedInAs: _old,
          linked: true,
          targetState: 'deleting',
        );
        await rig.requestCode();
        await expectLater(
          rig.coordinator.recover(email: _email, code: rig.port.signInCode!),
          failsWith(EmailAuthFailure.accountNotActive),
        );
        expect(rig.port.userId, isNull);
        expect(rig.events.last, 'clearDeviceData');
        expect(rig.events, contains('identityChanged'));
        expect(rig.marker.previousUserId, isNull);
      },
    );

    test('a push cleanup that fails blocks the switch: the session, the marker '
        'and the old user\'s registration state stay as they were', () async {
      final rig = await _rig(signedInAs: _old, linked: true)
        ..failPush = true;
      await rig.requestCode();
      await expectLater(
        rig.coordinator.recover(email: _email, code: rig.port.signInCode!),
        failsWith(EmailAuthFailure.pushCleanupFailed),
      );
      expect(rig.port.userId, _old, reason: 'no switch happened');
      expect(rig.port.calls, isNot(contains('verifySignInCode')));
      expect(rig.marker.previousUserId, isNull);
      expect(rig.events, ['unregisterPushToken(session=$_old)']);
    });

    test('a failing push cleanup also blocks signing out', () async {
      final rig = await _rig(signedInAs: _old, linked: true)
        ..failPush = true;
      await expectLater(
        rig.coordinator.signOut(),
        failsWith(EmailAuthFailure.pushCleanupFailed),
      );
      expect(rig.port.userId, _old);
      expect(rig.port.calls, isNot(contains('signOutLocal')));
    });

    test('a failed restore after a rejected code is not reported as success '
        'or failure of the sign-in (the next launch repeats it)', () async {
      final rig = await _rig(signedInAs: _old, linked: true)
        ..failRestore = true;
      await rig.requestCode();
      await expectLater(
        rig.coordinator.recover(email: _email, code: '000000'),
        failsWith(EmailAuthFailure.codeRejected),
      );
      expect(rig.port.userId, _old);
    });
  });

  group('process termination', () {
    test('a failed device cleanup is repeated at the next launch', () async {
      final rig = await _rig(signedInAs: _old, linked: true)
        ..failCleanup = true;
      await rig.requestCode();
      await rig.coordinator.recover(email: _email, code: rig.port.signInCode!);
      expect(rig.marker.previousUserId, _old, reason: 'cleanup is still owed');
      expect(rig.events, contains('identityChanged'));

      final cleaned = <String>[];
      await rig.marker.resumeIfPending(
        currentUserId: rig.port.userId,
        clearDeviceData: () async => cleaned.add('clear'),
      );
      expect(cleaned, ['clear']);
      expect(rig.marker.previousUserId, isNull);
    });

    test('a switch that never happened only forgets the marker', () async {
      final rig = await _rig(signedInAs: _old);
      await rig.marker.mark(_old);
      final cleaned = <String>[];
      await rig.marker.resumeIfPending(
        currentUserId: _old,
        clearDeviceData: () async => cleaned.add('clear'),
      );
      expect(cleaned, isEmpty);
      expect(rig.marker.previousUserId, isNull);
    });

    test('a sign-out cut short is finished at the next launch', () async {
      final rig = await _rig(signedInAs: _old);
      await rig.marker.mark(_old);
      final cleaned = <String>[];
      await rig.marker.resumeIfPending(
        currentUserId: null,
        clearDeviceData: () async => cleaned.add('clear'),
      );
      expect(cleaned, ['clear']);
    });

    test('with no marker, startup does nothing', () async {
      final rig = await _rig();
      var called = false;
      await rig.marker.resumeIfPending(
        currentUserId: _old,
        clearDeviceData: () async => called = true,
      );
      expect(called, isFalse);
    });

    test('the account-deletion marker is neither read nor removed', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.requestCode();
      await rig.coordinator.recover(email: _email, code: rig.port.signInCode!);
      await rig.marker.mark('x');
      await rig.marker.resumeIfPending(
        currentUserId: _target,
        clearDeviceData: () async {},
      );
      expect(AccountLocalCleanup(rig.prefs).markedUserId, 'user-being-deleted');
    });
  });

  group('local data isolation', () {
    test('each user keeps only their own pending financial requests', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.requestCode();
      await rig.coordinator.recover(email: _email, code: rig.port.signInCode!);
      final store = FinancialRequestStore(rig.prefs);
      List<String> ids(String user) => [
        for (final op in store.pending(
          userId: user,
          householdId: 'hh-1',
          kind: 'expense',
        ))
          op.requestId,
      ];
      expect(ids(_old), ['o1'], reason: 'not wiped, not moved');
      expect(ids(_target), ['t1']);
      expect(
        store.pending(userId: 'user-new', householdId: 'hh-1', kind: 'expense'),
        isEmpty,
        reason: 'a request id is only ever read under its own user',
      );
    });

    test('app-wide settings survive a switch', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.requestCode();
      await rig.coordinator.recover(email: _email, code: rig.port.signInCode!);
      expect(rig.prefs.getBool('reminder_enabled'), isTrue);
      expect(rig.prefs.getString('widget_privacy_mode'), 'show_names');
    });
  });

  group('signing out', () {
    test('a linked user signs out locally and the device is cleaned', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      await rig.coordinator.signOut();
      expect(rig.port.userId, isNull);
      expect(rig.events, [
        'unregisterPushToken(session=$_old)',
        'identityChanged',
        'clearDeviceData',
      ]);
      expect(rig.marker.previousUserId, isNull);
    });

    test('an unlinked anonymous user is not signed out silently', () async {
      final rig = await _rig(signedInAs: _old);
      await expectLater(
        rig.coordinator.signOut(),
        failsWith(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(rig.port.userId, _old);
      expect(rig.events, isEmpty);
    });

    test('an unverifiable identity never signs out', () async {
      final rig = await _rig(signedInAs: _old, linked: true);
      rig.port.identityError = StateError('offline');
      await expectLater(
        rig.coordinator.signOut(),
        throwsA(isA<EmailAuthException>()),
      );
      expect(rig.port.userId, _old);
      expect(rig.events, isEmpty);
    });

    test('signing out with no session does nothing', () async {
      final rig = await _rig();
      await rig.coordinator.signOut();
      expect(rig.events, isEmpty);
    });
  });
}
