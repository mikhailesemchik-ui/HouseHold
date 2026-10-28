import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_auth_port.dart';

Matcher failsWith(EmailAuthFailure failure) => throwsA(
  isA<EmailAuthException>().having((e) => e.failure, 'failure', failure),
);

void main() {
  late FakeAuthPort port;
  late EmailAccountRepository repo;

  void signedInAnonymous() {
    port = FakeAuthPort(userId: 'user-a');
    repo = EmailAccountRepository(port);
  }

  setUp(signedInAnonymous);

  group('linking an email to the current anonymous user', () {
    test(
      'sending a code is not verification and keeps the same user',
      () async {
        final identity = await repo.sendLinkCode('  Me@Example.test ');
        expect(identity.userId, 'user-a');
        expect(identity.pendingEmail, 'me@example.test');
        expect(identity.isAnonymous, isTrue);
        expect(identity.isLinked, isFalse);
      },
    );

    test('the right code links the account with the same user id', () async {
      await repo.sendLinkCode('me@example.test');
      final identity = await repo.verifyLinkCode(
        expectedUserId: 'user-a',
        email: 'ME@example.test',
        code: ' ${port.linkCode} ',
      );
      expect(identity.userId, 'user-a');
      expect(identity.isLinked, isTrue);
      expect(identity.email, 'me@example.test');
      expect(port.userId, 'user-a');
    });

    test('a wrong code is rejected and the account stays anonymous', () async {
      await repo.sendLinkCode('me@example.test');
      await expectLater(
        repo.verifyLinkCode(
          expectedUserId: 'user-a',
          email: 'me@example.test',
          code: '000000',
        ),
        failsWith(EmailAuthFailure.codeRejected),
      );
      expect((await repo.currentIdentity()).isAnonymous, isTrue);
    });

    test('a malformed code never reaches the server', () async {
      await repo.sendLinkCode('me@example.test');
      port.calls.clear();
      for (final bad in ['', '12345', '1234567', 'abcdef', '12 456']) {
        await expectLater(
          repo.verifyLinkCode(
            expectedUserId: 'user-a',
            email: 'me@example.test',
            code: bad,
          ),
          failsWith(EmailAuthFailure.codeRejected),
        );
      }
      expect(port.calls, isEmpty);
    });

    test('a used code cannot be replayed', () async {
      await repo.sendLinkCode('me@example.test');
      final code = port.linkCode!;
      await repo.verifyLinkCode(
        expectedUserId: 'user-a',
        email: 'me@example.test',
        code: code,
      );
      await expectLater(
        repo.verifyLinkCode(
          expectedUserId: 'user-a',
          email: 'me@example.test',
          code: code,
        ),
        failsWith(EmailAuthFailure.codeRejected),
      );
    });

    test(
      'resending is another request that invalidates the old code',
      () async {
        await repo.sendLinkCode('me@example.test');
        final first = port.linkCode!;
        await repo.sendLinkCode('me@example.test');
        final second = port.linkCode!;
        expect(second, isNot(first));
        await expectLater(
          repo.verifyLinkCode(
            expectedUserId: 'user-a',
            email: 'me@example.test',
            code: first,
          ),
          failsWith(EmailAuthFailure.codeRejected),
        );
        final identity = await repo.verifyLinkCode(
          expectedUserId: 'user-a',
          email: 'me@example.test',
          code: second,
        );
        expect(identity.isLinked, isTrue);
      },
    );

    test('a double tap sends one request', () async {
      final a = repo.sendLinkCode('me@example.test');
      final b = repo.sendLinkCode('me@example.test');
      await Future.wait([a, b]);
      expect(
        port.calls.where((c) => c.startsWith('requestEmailChange')),
        hasLength(1),
      );
      await repo.sendLinkCode('me@example.test');
      expect(
        port.calls.where((c) => c.startsWith('requestEmailChange')),
        hasLength(2),
        reason: 'a later request is not swallowed',
      );
    });

    test(
      'an email owned by another account is refused without side effects',
      () async {
        port.takenEmails.add('taken@example.test');
        await expectLater(
          repo.sendLinkCode('taken@example.test'),
          failsWith(EmailAuthFailure.emailInUse),
        );
        final identity = await repo.currentIdentity();
        expect(identity.pendingEmail, isNull);
        expect(identity.isAnonymous, isTrue);
      },
    );

    test('an invalid address fails fast without a server call', () async {
      for (final bad in ['', 'plain', '@x.test', 'a@', 'a@b@c.test']) {
        await expectLater(
          repo.sendLinkCode(bad),
          failsWith(EmailAuthFailure.invalidEmail),
        );
      }
      expect(port.calls.where((c) => c.startsWith('request')), isEmpty);
    });

    test('a user change between request and verify sends nothing', () async {
      await repo.sendLinkCode('me@example.test');
      final code = port.linkCode!;
      port.userId = 'someone-else';
      port.calls.clear();
      await expectLater(
        repo.verifyLinkCode(
          expectedUserId: 'user-a',
          email: 'me@example.test',
          code: code,
        ),
        failsWith(EmailAuthFailure.sessionChanged),
      );
      expect(port.calls, isEmpty);
    });

    test('an already linked user cannot start another link', () async {
      port
        ..anonymous = false
        ..email = 'old@example.test';
      await expectLater(
        repo.sendLinkCode('new@example.test'),
        failsWith(EmailAuthFailure.alreadyLinked),
      );
    });

    test('deleting and deleted profiles cannot link an email', () async {
      for (final state in ['deleting', 'deleted']) {
        port.accountState = state;
        await expectLater(
          repo.sendLinkCode('me@example.test'),
          failsWith(EmailAuthFailure.accountNotActive),
        );
      }
      expect(
        port.calls.where((c) => c.startsWith('requestEmailChange')),
        isEmpty,
      );
    });

    test('without a session nothing is sent', () async {
      port.userId = null;
      await expectLater(
        repo.sendLinkCode('me@example.test'),
        failsWith(EmailAuthFailure.notSignedIn),
      );
    });

    test(
      'a pending email survives an app restart (it lives on the server)',
      () async {
        await repo.sendLinkCode('me@example.test');
        final code = port.linkCode!;
        final restarted = EmailAccountRepository(port);
        final identity = await restarted.currentIdentity();
        expect(identity.pendingEmail, 'me@example.test');
        final linked = await restarted.verifyLinkCode(
          expectedUserId: identity.userId,
          email: identity.pendingEmail!,
          code: code,
        );
        expect(linked.isLinked, isTrue);
      },
    );
  });

  group('error mapping', () {
    test('transport and server errors become safe typed failures', () async {
      final cases = <Object, EmailAuthFailure>{
        AuthRetryableFetchException(): EmailAuthFailure.network,
        const SocketException('Failed host lookup: secret.host'):
            EmailAuthFailure.network,
        const AuthApiException('boom', statusCode: '500'):
            EmailAuthFailure.serverError,
        const AuthApiException(
          'slow down',
          statusCode: '429',
          code: 'over_email_send_rate_limit',
        ): EmailAuthFailure.rateLimited,
        StateError('anything else'): EmailAuthFailure.serverError,
      };
      for (final entry in cases.entries) {
        port.requestError = entry.key;
        await expectLater(
          repo.sendLinkCode('me@example.test'),
          failsWith(entry.value),
          reason: '${entry.key}',
        );
      }
    });

    test('a failed request leaves the anonymous session usable', () async {
      port.requestError = AuthRetryableFetchException();
      await expectLater(
        repo.sendLinkCode('me@example.test'),
        failsWith(EmailAuthFailure.network),
      );
      port.requestError = null;
      expect(port.userId, 'user-a');
      await repo.sendLinkCode('me@example.test');
      expect(port.pending, 'me@example.test');
    });

    test('failures never expose server text, codes or tokens', () {
      const secret = 'eyJ.secret.token 123456';
      final e = EmailAuthException(
        mapEmailAuthError(
          const AuthApiException(secret, statusCode: '500'),
          EmailAuthStep.verifyCode,
        ),
      );
      expect(e.toString(), isNot(contains('eyJ')));
      expect(e.toString(), isNot(contains('123456')));
    });
  });

  group('recovery on a device without a session', () {
    setUp(() {
      port = FakeAuthPort(userId: null);
      port.accounts['me@example.test'] = 'user-a';
      repo = EmailAccountRepository(port);
    });

    test(
      'an unknown address gets the same quiet result and creates nothing',
      () async {
        await repo.sendRecoveryCode('nobody@example.test');
        expect(port.userId, isNull);
        expect(port.signInCode, isNull);
      },
    );

    test('a known address sends a code but does not sign in', () async {
      await repo.sendRecoveryCode('Me@Example.test');
      expect(port.signInCode, isNotNull);
      expect(port.userId, isNull);
    });

    test('the right code restores the SAME user id', () async {
      await repo.sendRecoveryCode('me@example.test');
      final identity = await repo.verifyRecoveryCode(
        email: 'me@example.test',
        code: port.signInCode!,
      );
      expect(identity.userId, 'user-a');
      expect(identity.isLinked, isTrue);
      expect(port.userId, 'user-a');
    });

    test('a wrong or reused code leaves the device signed out', () async {
      await repo.sendRecoveryCode('me@example.test');
      final code = port.signInCode!;
      await expectLater(
        repo.verifyRecoveryCode(email: 'me@example.test', code: '000000'),
        failsWith(EmailAuthFailure.codeRejected),
      );
      expect(port.userId, isNull);
      await repo.verifyRecoveryCode(email: 'me@example.test', code: code);
      port.userId = null;
      await expectLater(
        repo.verifyRecoveryCode(email: 'me@example.test', code: code),
        failsWith(EmailAuthFailure.codeRejected),
      );
    });

    test('a deleting account is signed out again and refused', () async {
      port.accountStates['user-a'] = 'deleting';
      await repo.sendRecoveryCode('me@example.test');
      await expectLater(
        repo.verifyRecoveryCode(
          email: 'me@example.test',
          code: port.signInCode!,
        ),
        failsWith(EmailAuthFailure.accountNotActive),
      );
      expect(port.userId, isNull);
    });

    test(
      'an unreadable account state keeps the session (the database still enforces access)',
      () async {
        await repo.sendRecoveryCode('me@example.test');
        port.stateError = AuthRetryableFetchException();
        final identity = await repo.verifyRecoveryCode(
          email: 'me@example.test',
          code: port.signInCode!,
        );
        expect(identity.userId, 'user-a');
        expect(port.userId, 'user-a');
      },
    );
  });

  group('protecting an anonymous account that has no recovery email', () {
    setUp(() {
      port = FakeAuthPort(userId: 'user-anon');
      port.accounts['me@example.test'] = 'user-a';
      repo = EmailAccountRepository(port);
    });

    test(
      'recovery over an unlinked anonymous session is refused untouched',
      () async {
        await repo.sendRecoveryCode('me@example.test');
        port.calls.clear();
        await expectLater(
          repo.verifyRecoveryCode(
            email: 'me@example.test',
            code: port.signInCode!,
          ),
          failsWith(EmailAuthFailure.anonymousAccountAtRisk),
        );
        expect(port.calls, isEmpty);
        expect(port.userId, 'user-anon');
      },
    );

    test('an explicit acknowledgement allows the switch', () async {
      await repo.sendRecoveryCode('me@example.test');
      final identity = await repo.verifyRecoveryCode(
        email: 'me@example.test',
        code: port.signInCode!,
        acknowledgeAnonymousLoss: true,
      );
      expect(identity.userId, 'user-a');
    });

    test(
      'sign-out of an unlinked anonymous user needs acknowledgement',
      () async {
        await expectLater(
          repo.assertCanSignOut(acknowledgeAnonymousLoss: false),
          failsWith(EmailAuthFailure.anonymousAccountAtRisk),
        );
        await repo.assertCanSignOut(acknowledgeAnonymousLoss: true);
      },
    );

    test(
      'a linked user may sign out, and a failed check never signs out',
      () async {
        port
          ..anonymous = false
          ..email = 'me@example.test';
        await repo.assertCanSignOut(acknowledgeAnonymousLoss: false);
        port.identityError = AuthRetryableFetchException();
        await expectLater(
          repo.assertCanSignOut(acknowledgeAnonymousLoss: false),
          failsWith(EmailAuthFailure.network),
        );
        expect(port.userId, 'user-anon');
      },
    );
  });
}
