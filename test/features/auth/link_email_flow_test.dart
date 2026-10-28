import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/auth/presentation/link_email_flow.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';

import 'fake_auth_port.dart';

const _address = 'me@example.test';

class _Rig {
  _Rig(this.port) {
    container = ProviderContainer(
      overrides: [
        emailAccountRepositoryProvider.overrideWithValue(
          EmailAccountRepository(port),
        ),
        recoveryClockProvider.overrideWithValue(() => now),
      ],
    );
    container.listen(linkEmailFlowProvider, (_, _) {}, fireImmediately: true);
  }

  final FakeAuthPort port;
  DateTime now = DateTime(2026, 1, 1, 12);
  late final ProviderContainer container;

  LinkEmailFlowNotifier get flow =>
      container.read(linkEmailFlowProvider.notifier);
  LinkEmailState get state => container.read(linkEmailFlowProvider);
  int get requests =>
      port.calls.where((c) => c.startsWith('requestEmailChange')).length;
}

_Rig _anon() => _Rig(FakeAuthPort(userId: 'user-a'));

void main() {
  test('protection comes from the server identity, not a submitted email', () {
    const anon = AuthIdentity(userId: 'u', isAnonymous: true);
    const pending = AuthIdentity(
      userId: 'u',
      isAnonymous: true,
      pendingEmail: _address,
    );
    const linked = AuthIdentity(
      userId: 'u',
      isAnonymous: false,
      email: _address,
      isEmailConfirmed: true,
    );
    const unconfirmed = AuthIdentity(
      userId: 'u',
      isAnonymous: false,
      email: _address,
    );
    expect(protectionOf(anon), isA<AccountUnprotected>());
    expect(protectionOf(pending), isA<AccountVerificationPending>());
    expect(protectionOf(linked), isA<AccountProtected>());
    expect(protectionOf(unconfirmed), isNull);
  });

  test(
    'a code request uses the current anonymous user and stays pending',
    () async {
      final rig = _anon();
      await rig.flow.requestCode(' Me@Example.test ');
      final s = rig.state as LinkEmailCodeEntry;
      expect(s.userId, 'user-a');
      expect(s.email, _address);
      expect(rig.port.pending, _address);
      expect(
        rig.port.anonymous,
        isTrue,
        reason: 'not protected before the code',
      );
      expect(rig.port.calls, isNot(contains('verifyEmailChange')));
    },
  );

  test('an invalid address is rejected before any request', () async {
    final rig = _anon();
    await rig.flow.requestCode('not-an-email');
    expect(
      (rig.state as LinkEmailEntry).failure,
      EmailAuthFailure.invalidEmail,
    );
    expect(rig.requests, 0);
  });

  test('the right code links the SAME user, confirmed by the server', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    await rig.flow.verify(rig.port.linkCode!);
    final done = rig.state as LinkEmailDone;
    expect(done.identity.userId, 'user-a');
    expect(done.identity.isLinked, isTrue);
    expect(rig.port.userId, 'user-a');
  });

  test('a wrong code is rejected and the account stays anonymous', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    await rig.flow.verify('000000');
    expect(
      (rig.state as LinkEmailCodeEntry).failure,
      EmailAuthFailure.codeRejected,
    );
    expect(rig.port.anonymous, isTrue);
    expect(rig.port.userId, 'user-a');
  });

  test('a malformed code never reaches the server', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    await rig.flow.verify('12ab');
    expect(rig.port.calls, isNot(contains('verifyEmailChange')));
    expect(
      (rig.state as LinkEmailCodeEntry).failure,
      EmailAuthFailure.codeRejected,
    );
  });

  test('a linked account cannot start linking again', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    await rig.flow.verify(rig.port.linkCode!);
    final again = _Rig(rig.port);
    await again.flow.requestCode(_address);
    expect(
      (again.state as LinkEmailEntry).failure,
      EmailAuthFailure.alreadyLinked,
    );
    again.container.dispose();
    rig.container.dispose();
  });

  test(
    'resend is another updateUser(email), after the cooldown only',
    () async {
      final rig = _anon();
      await rig.flow.requestCode(_address);
      expect(rig.requests, 1);
      await rig.flow.resend();
      expect(rig.requests, 1, reason: 'still cooling down');
      rig.now = rig.now.add(recoveryResendCooldown);
      final firstCode = rig.port.linkCode;
      await rig.flow.resend();
      expect(rig.requests, 2);
      expect(rig.port.linkCode, isNot(firstCode));
      expect(rig.port.userId, 'user-a', reason: 'no second identity');
    },
  );

  test('a second tap while resend is in flight is ignored', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    rig.now = rig.now.add(recoveryResendCooldown);
    await Future.wait([rig.flow.resend(), rig.flow.resend()]);
    expect(rig.requests, 2, reason: 'one initial request plus one resend');
  });

  test('a second tap on Send code is ignored', () async {
    final rig = _anon();
    await Future.wait([
      rig.flow.requestCode(_address),
      rig.flow.requestCode(_address),
    ]);
    expect(rig.requests, 1);
  });

  test('an email of another account is reported and not bound', () async {
    final rig = _anon();
    rig.port.takenEmails.add(_address);
    await rig.flow.requestCode(_address);
    expect((rig.state as LinkEmailEntry).failure, EmailAuthFailure.emailInUse);
    expect(rig.port.pending, isNull);
  });

  test('a user change during verification sends nothing', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    final code = rig.port.linkCode!;
    rig.port.userId = 'user-b';
    await rig.flow.verify(code);
    expect(
      (rig.state as LinkEmailCodeEntry).failure,
      EmailAuthFailure.sessionChanged,
    );
    expect(rig.port.calls, isNot(contains('verifyEmailChange')));
    expect(rig.port.userId, 'user-b');
  });

  test('an unexpected server failure is safe, never a success', () async {
    final rig = _anon();
    await rig.flow.requestCode(_address);
    rig.port.verifyError = StateError('raw sdk detail');
    await rig.flow.verify(rig.port.linkCode!);
    expect(
      (rig.state as LinkEmailCodeEntry).failure,
      EmailAuthFailure.serverError,
    );
    expect(rig.port.anonymous, isTrue);
  });

  test(
    'a pending verification resumes after a restart, no extra mail',
    () async {
      final rig = _anon();
      await rig.flow.requestCode(_address);
      final code = rig.port.linkCode!;
      final restarted = _Rig(rig.port); // fresh app, same server state
      restarted.flow.resumePending(
        const AccountVerificationPending('user-a', _address),
      );
      expect(restarted.state, isA<LinkEmailCodeEntry>());
      expect(restarted.requests, 1);
      await restarted.flow.verify(code);
      expect(restarted.state, isA<LinkEmailDone>());
      restarted.container.dispose();
      rig.container.dispose();
    },
  );

  test('signed out: nothing is requested', () async {
    final rig = _Rig(FakeAuthPort());
    await rig.flow.requestCode(_address);
    expect((rig.state as LinkEmailEntry).failure, EmailAuthFailure.notSignedIn);
    expect(rig.requests, 0);
  });

  test('a deleting account cannot start linking', () async {
    final rig = _Rig(FakeAuthPort(userId: 'user-a', accountState: 'deleting'));
    await rig.flow.requestCode(_address);
    expect(
      (rig.state as LinkEmailEntry).failure,
      EmailAuthFailure.accountNotActive,
    );
    expect(rig.port.pending, isNull);
  });
}
