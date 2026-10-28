// Real-SDK verification of F1 (email linking and recovery) against the
// ISOLATED local Supabase stack. Not part of `flutter test` (outside test/).
//
//   HH_ALLOW_STACK=hhsqltest HH_AUTH_URL=http://127.0.0.1:55421 \
//   HH_ANON_KEY=... HH_SERVICE_KEY=... HH_MAIL_URL=http://127.0.0.1:55424 \
//   HH_IDS_FILE=<path> flutter test test_local_auth/f1_sdk_verification_test.dart
//
// The local stack must run with email confirmations ON, code-only templates
// and mail capture. Uses disposable anonymous users only; their ids are
// appended to HH_IDS_FILE for cleanup. Nothing here is a mock.
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_stack.dart';

void main() {
  if (!stackEnabled) {
    test('skipped: isolated local stack not configured', () {}, skip: true);
    return;
  }

  late SupabaseClient admin;
  setUpAll(() {
    admin = SupabaseClient(env['HH_AUTH_URL']!, env['HH_SERVICE_KEY']!);
  });
  tearDownAll(() async {
    for (final id in created) {
      try {
        await admin.auth.admin.deleteUser(id);
      } catch (_) {}
    }
    await admin.dispose();
  });

  test('PKCE link -> verify -> sign out -> recover keeps the same uuid', () async {
    await mailApi('/api/v1/messages', method: 'DELETE');
    final users0 = await userCount(admin);

    // A: anonymous user with a profile, a household and an expense.
    final pkceA = MemoryPkceStorage();
    final a = newClient(pkceA);
    final anon = await a.auth.signInAnonymously();
    final aId = anon.user!.id;
    track(aId);
    expect(anon.user!.isAnonymous, isTrue);
    await a.from('profiles').insert({
      'user_id': aId,
      'public_id': 'SDK-$runId',
      'display_name': 'Sdk A',
    });
    final household = await a.rpc(
      'create_household',
      params: {'p_name': 'SDK F1'},
    );
    final hId = household['id'] as String;
    await a.rpc(
      'create_equal_split_expense',
      params: {
        'p_household_id': hId,
        'p_title': 'SDK dinner',
        'p_amount_cents': 3000,
        'p_currency': 'EUR',
        'p_paid_by': aId,
        'p_participant_ids': [aId],
      },
    );
    final before = (await admin
        .from('expenses')
        .select('id, amount_cents, paid_by')
        .eq('household_id', hId));
    final profilesAfterSetup = await rowCount(admin, 'profiles');

    // Link: updateUser(email).
    final email = 'sdk-a-$runId@example.test';
    final updated = await a.auth.updateUser(UserAttributes(email: email));
    expect(updated.user!.id, aId);
    expect(updated.user!.newEmail, email);
    expect(
      updated.user!.isAnonymous,
      isTrue,
      reason: 'not linked until verified',
    );
    final storedKeys = pkceA.values.keys.toList();
    // ignore: avoid_print
    print('PKCE verifier keys after updateUser: $storedKeys');
    expect(storedKeys, isNotEmpty, reason: 'SDK stored a PKCE verifier');
    final linkMail = await mailTo(email);
    expect(linkMail, hasLength(1));
    // ignore: avoid_print
    print('link mail subject: ${subjectOf(linkMail.first)}');

    // Wrong code: rejected, anonymous session intact.
    await expectLater(
      a.auth.verifyOTP(
        email: email,
        token: '000000',
        type: OtpType.emailChange,
      ),
      throwsA(
        isA<AuthApiException>().having((e) => e.code, 'code', 'otp_expired'),
      ),
    );
    expect((await a.auth.getUser()).user!.isAnonymous, isTrue);

    // Wrong OTP types with the right code do not link (and do not consume it).
    final code = await latestCode(email);
    for (final wrong in [OtpType.email, OtpType.signup]) {
      await expectLater(
        a.auth.verifyOTP(email: email, token: code, type: wrong),
        throwsA(isA<AuthException>()),
      );
    }

    // Right code, emailChange: same uuid, now permanent.
    final verified = await a.auth.verifyOTP(
      email: email,
      token: code,
      type: OtpType.emailChange,
    );
    expect(verified.session, isNotNull);
    expect(verified.user!.id, aId);
    expect(verified.user!.isAnonymous, isFalse);
    expect(verified.user!.email, email);
    expect(a.auth.currentUser!.id, aId);
    expect(claims(a.auth.currentSession!.accessToken)['is_anonymous'], isFalse);
    expect(claims(a.auth.currentSession!.accessToken)['sub'], aId);

    // Replay of a used code.
    await expectLater(
      a.auth.verifyOTP(email: email, token: code, type: OtpType.emailChange),
      throwsA(isA<AuthApiException>()),
    );
    expect(await userCount(admin), users0 + 1, reason: 'no second Auth user');
    expect(await rowCount(admin, 'profiles'), profilesAfterSetup);

    // Refresh keeps the identity.
    final refreshed = await a.auth.refreshSession();
    expect(refreshed.user!.id, aId);
    expect(refreshed.user!.isAnonymous, isFalse);

    // Sign out and recover on a fresh client (a "reinstalled" device).
    await a.auth.signOut();
    expect(a.auth.currentSession, isNull);
    await a.dispose();

    final pkceF = MemoryPkceStorage();
    final fresh = newClient(pkceF);
    expect(
      fresh.auth.currentSession,
      isNull,
      reason: 'no session before recovery',
    );
    await mailApi('/api/v1/messages', method: 'DELETE');
    await fresh.auth.signInWithOtp(email: email, shouldCreateUser: false);
    expect(
      fresh.auth.currentSession,
      isNull,
      reason: 'sending a code is not a sign-in',
    );
    // ignore: avoid_print
    print(
      'PKCE verifier keys after signInWithOtp: ${pkceF.values.keys.toList()}',
    );
    final recoverMail = await mailTo(email);
    expect(recoverMail, hasLength(1));
    // ignore: avoid_print
    print('recovery mail subject: ${subjectOf(recoverMail.first)}');
    final rcode = await latestCode(email);

    await expectLater(
      fresh.auth.verifyOTP(email: email, token: '000000', type: OtpType.email),
      throwsA(isA<AuthApiException>()),
    );
    expect(fresh.auth.currentSession, isNull);
    await expectLater(
      fresh.auth.verifyOTP(
        email: email,
        token: rcode,
        type: OtpType.emailChange,
      ),
      throwsA(isA<AuthException>()),
    );
    final recovered = await fresh.auth.verifyOTP(
      email: email,
      token: rcode,
      type: OtpType.email,
    );
    expect(
      recovered.session,
      isNotNull,
      reason: 'OTP verify returns a session under PKCE',
    );
    // ignore: avoid_print
    print(
      'original=${aId.substring(0, 8)}.. recovered=${recovered.user!.id.substring(0, 8)}..',
    );
    expect(recovered.user!.id, aId, reason: 'RECOVERED UUID == ORIGINAL UUID');
    expect(recovered.user!.isAnonymous, isFalse);
    expect(await userCount(admin), users0 + 1);
    expect(await rowCount(admin, 'profiles'), profilesAfterSetup);

    // Existing data is reachable through RLS as the recovered identity.
    final profile = await fresh
        .from('profiles')
        .select('public_id')
        .eq('user_id', aId);
    expect(profile.single['public_id'], 'SDK-$runId');
    final members = await fresh
        .from('household_members')
        .select('user_id')
        .eq('household_id', hId)
        .eq('status', 'active');
    expect(members, hasLength(1));
    final after = await fresh
        .from('expenses')
        .select('id, amount_cents, paid_by')
        .eq('household_id', hId);
    expect(after, before);
    await fresh.dispose();
  });

  test(
    'resend of the link code needs updateUser again; auth.resend is a no-op',
    () async {
      await mailApi('/api/v1/messages', method: 'DELETE');
      final c = newClient(MemoryPkceStorage());
      final user = (await c.auth.signInAnonymously()).user!;
      track(user.id);
      final email = 'sdk-resend-$runId@example.test';
      await c.auth.updateUser(UserAttributes(email: email));
      final first = await latestCode(email);
      await mailApi('/api/v1/messages', method: 'DELETE');

      await c.auth.resend(type: OtpType.emailChange, email: email);
      expect(
        await mailTo(email),
        isEmpty,
        reason: 'resend() sent nothing for this user',
      );

      // The server enforces a minimum interval between mails (429 before it).
      await Future<void>.delayed(const Duration(seconds: 2));
      await c.auth.updateUser(UserAttributes(email: email));
      final second = await latestCode(email);
      expect(second, isNot(first));
      await expectLater(
        c.auth.verifyOTP(email: email, token: first, type: OtpType.emailChange),
        throwsA(isA<AuthException>()),
        reason: 'the old code is invalid after a new one is issued',
      );
      final ok = await c.auth.verifyOTP(
        email: email,
        token: second,
        type: OtpType.emailChange,
      );
      expect(ok.user!.id, user.id);
      await c.dispose();
    },
  );

  test(
    'unknown email with shouldCreateUser:false: 422, no user, no mail',
    () async {
      await mailApi('/api/v1/messages', method: 'DELETE');
      final users0 = await userCount(admin);
      final c = newClient(MemoryPkceStorage());
      await expectLater(
        c.auth.signInWithOtp(
          email: 'sdk-nobody-$runId@example.test',
          shouldCreateUser: false,
        ),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.statusCode, 'status', '422')
              .having((e) => e.code, 'code', 'otp_disabled'),
        ),
      );
      expect(c.auth.currentSession, isNull);
      expect(await userCount(admin), users0);
      expect(await mailTo('sdk-nobody-$runId@example.test'), isEmpty);
      await c.dispose();
    },
  );

  test(
    'email already linked to another user is rejected and harmless',
    () async {
      await mailApi('/api/v1/messages', method: 'DELETE');
      final owner = newClient(MemoryPkceStorage());
      track((await owner.auth.signInAnonymously()).user!.id);
      final taken = 'sdk-taken-$runId@example.test';
      await owner.auth.updateUser(UserAttributes(email: taken));
      await owner.auth.verifyOTP(
        email: taken,
        token: await latestCode(taken),
        type: OtpType.emailChange,
      );
      await mailApi('/api/v1/messages', method: 'DELETE');
      final c = newClient(MemoryPkceStorage());
      track((await c.auth.signInAnonymously()).user!.id);
      await expectLater(
        c.auth.updateUser(UserAttributes(email: taken)),
        throwsA(
          isA<AuthApiException>().having((e) => e.code, 'code', 'email_exists'),
        ),
      );
      final me = (await c.auth.getUser()).user!;
      expect(me.isAnonymous, isTrue);
      expect(me.newEmail, isNull);
      expect(await mailTo(taken), isEmpty);
      await owner.dispose();
      await c.dispose();
    },
  );
}
