// ignore_for_file: invalid_use_of_visible_for_testing_member
// REAL integration of the F1 repository and session coordinator (through
// SupabaseAuthPort) against the ISOLATED local stack. Not part of
// `flutter test`. See local_stack.dart and f1_sdk_verification_test.dart for
// the required environment and stack configuration. No mocks of Auth here;
// only SharedPreferences uses in-memory values.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_stack.dart';

Matcher failsWith(EmailAuthFailure failure) => throwsA(
  isA<EmailAuthException>().having((e) => e.failure, 'failure', failure),
);

class Device {
  Device(this.client) : repo = EmailAccountRepository(SupabaseAuthPort(client));

  final SupabaseClient client;
  final EmailAccountRepository repo;
  final events = <String>[];

  Future<SessionSwitchCoordinator> coordinator() async {
    final prefs = await SharedPreferences.getInstance();
    return SessionSwitchCoordinator(
      repository: repo,
      marker: SessionSwitchMarker(prefs),
      unregisterPushToken: () async => events.add('unregisterPushToken'),
      restorePushRegistration: () async =>
          events.add('restorePushRegistration'),
      clearDeviceData: () async => events.add('clearDeviceData'),
      onIdentityChanged: () => events.add('identityChanged'),
    );
  }
}

Device newDevice() => Device(newClient(MemoryPkceStorage()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!stackEnabled) {
    test('skipped: isolated local stack not configured', () {}, skip: true);
    return;
  }

  late SupabaseClient admin;
  setUpAll(() {
    HttpOverrides.global = null; // allow real HTTP under the test binding
    admin = SupabaseClient(env['HH_AUTH_URL']!, env['HH_SERVICE_KEY']!);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await mailApi('/api/v1/messages', method: 'DELETE');
  });
  tearDownAll(() async {
    for (final id in created) {
      try {
        await admin.auth.admin.deleteUser(id);
      } catch (_) {}
    }
    await admin.dispose();
  });

  Future<String> signInAnonymouslyWithProfile(Device d, String tag) async {
    final id = (await d.client.auth.signInAnonymously()).user!.id;
    track(id);
    await d.client.from('profiles').insert({
      'user_id': id,
      'public_id': 'R$tag-$runId',
      'display_name': 'Repo $tag',
    });
    return id;
  }

  Future<String> linkedUser(String email, String tag) async {
    final d = newDevice();
    final id = await signInAnonymouslyWithProfile(d, tag);
    await d.repo.sendLinkCode(email);
    await d.repo.verifyLinkCode(
      expectedUserId: id,
      email: email,
      code: await latestCode(email),
    );
    await d.client.auth.signOut();
    await d.client.dispose();
    return id;
  }

  test('link -> sign out -> recover keeps the uuid, data and counts', () async {
    final users0 = await userCount(admin);
    final a = newDevice();
    final aId = await signInAnonymouslyWithProfile(a, 'A');
    final household = await a.client.rpc(
      'create_household',
      params: {'p_name': 'Repo F1'},
    );
    final hId = household['id'] as String;
    await a.client.rpc(
      'create_equal_split_expense',
      params: {
        'p_household_id': hId,
        'p_title': 'Repo dinner',
        'p_amount_cents': 4200,
        'p_currency': 'EUR',
        'p_paid_by': aId,
        'p_participant_ids': [aId],
      },
    );
    final expensesBefore = await admin
        .from('expenses')
        .select('id, amount_cents, paid_by')
        .eq('household_id', hId);
    final profiles = await rowCount(admin, 'profiles');

    final email = 'repo-a-$runId@example.test';
    final pending = await a.repo.sendLinkCode(email);
    expect(pending.userId, aId);
    expect(pending.pendingEmail, email);
    expect(pending.isLinked, isFalse, reason: 'a sent mail is not a link');

    // The pending email lives on the server: a fresh repository sees it.
    final restarted = EmailAccountRepository(SupabaseAuthPort(a.client));
    expect((await restarted.currentIdentity()).pendingEmail, email);

    await expectLater(
      a.repo.verifyLinkCode(expectedUserId: aId, email: email, code: '000000'),
      failsWith(EmailAuthFailure.codeRejected),
    );
    await expectLater(
      a.repo.verifyLinkCode(
        expectedUserId: 'another-user',
        email: email,
        code: await latestCode(email),
      ),
      failsWith(EmailAuthFailure.sessionChanged),
    );
    final linked = await a.repo.verifyLinkCode(
      expectedUserId: aId,
      email: email,
      code: await latestCode(email),
    );
    expect(linked.userId, aId);
    expect(linked.isLinked, isTrue);
    expect((await a.repo.currentIdentity()).isLinked, isTrue);
    await expectLater(
      a.repo.sendLinkCode('second-$runId@example.test'),
      failsWith(EmailAuthFailure.alreadyLinked),
    );

    // Sign out through the coordinator (linked: no acknowledgement needed).
    await (await a.coordinator()).signOut();
    expect(a.client.auth.currentSession, isNull);
    expect(a.events, contains('clearDeviceData'));

    // A fresh device: no session, so nothing can create an anonymous user.
    final f = newDevice();
    expect(f.client.auth.currentSession, isNull);
    final unknown = 'repo-nobody-$runId@example.test';
    await f.repo.sendRecoveryCode(unknown); // quiet, non-disclosing
    expect(await mailTo(unknown), isEmpty);
    expect(f.client.auth.currentSession, isNull);
    expect(await userCount(admin), users0 + 1, reason: 'no user was created');

    await f.repo.sendRecoveryCode(email);
    final code = await latestCode(email);
    final coordinator = await f.coordinator();
    await expectLater(
      coordinator.recover(email: email, code: '000000'),
      failsWith(EmailAuthFailure.codeRejected),
    );
    expect(f.client.auth.currentSession, isNull);
    final recovered = await coordinator.recover(email: email, code: code);
    // ignore: avoid_print
    print(
      'original=${aId.substring(0, 8)}.. recovered=${recovered.userId.substring(0, 8)}..',
    );
    expect(recovered.userId, aId, reason: 'RECOVERED UUID == ORIGINAL UUID');
    expect(f.client.auth.currentUser!.id, aId);
    expect(f.events, ['identityChanged', 'clearDeviceData']);

    // Same data through RLS, no extra users or profiles.
    expect(await userCount(admin), users0 + 1);
    expect(await rowCount(admin, 'profiles'), profiles);
    final members = await f.client
        .from('household_members')
        .select('user_id')
        .eq('household_id', hId)
        .eq('status', 'active');
    expect(members, hasLength(1));
    final expensesAfter = await f.client
        .from('expenses')
        .select('id, amount_cents, paid_by')
        .eq('household_id', hId);
    expect(expensesAfter, expensesBefore);

    // The recovery code cannot be replayed.
    final g = newDevice();
    await expectLater(
      g.repo.verifyRecoveryCode(email: email, code: code),
      failsWith(EmailAuthFailure.codeRejected),
    );
    await a.client.dispose();
    await f.client.dispose();
    await g.client.dispose();
  });

  test(
    'an unlinked anonymous account is protected; a taken email is refused',
    () async {
      final taken = 'repo-taken-$runId@example.test';
      await linkedUser(taken, 'T');
      await mailApi('/api/v1/messages', method: 'DELETE');

      final d = newDevice();
      final id = await signInAnonymouslyWithProfile(d, 'B');
      await expectLater(
        d.repo.sendLinkCode(taken),
        failsWith(EmailAuthFailure.emailInUse),
      );
      expect(await mailTo(taken), isEmpty);
      expect((await d.repo.currentIdentity()).isAnonymous, isTrue);

      await d.repo.sendRecoveryCode(taken);
      final code = await latestCode(taken);
      final coordinator = await d.coordinator();
      await expectLater(
        coordinator.recover(email: taken, code: code),
        failsWith(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(d.client.auth.currentUser!.id, id, reason: 'session untouched');
      expect(d.events, isEmpty);
      await expectLater(
        coordinator.signOut(),
        failsWith(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(d.client.auth.currentUser!.id, id);
      await d.client.dispose();
    },
  );

  test('an unreachable server maps to a network failure', () async {
    final dead = Device(
      SupabaseClient(
        'http://127.0.0.1:9',
        env['HH_ANON_KEY']!,
        authOptions: AuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          pkceAsyncStorage: MemoryPkceStorage(),
        ),
      ),
    );
    await expectLater(
      dead.repo.sendRecoveryCode('someone@example.test'),
      failsWith(EmailAuthFailure.network),
    );
    await dead.client.dispose();
  });

  test(
    'deleting accounts cannot link, and a linked deleting account cannot recover',
    () async {
      // A deleting anonymous user cannot start linking.
      final y = newDevice();
      final yId = await signInAnonymouslyWithProfile(y, 'Y');
      expect(
        await admin.rpc('begin_account_deletion', params: {'p_user_id': yId}),
        'deleting',
      );
      await expectLater(
        y.repo.sendLinkCode('repo-y-$runId@example.test'),
        failsWith(EmailAuthFailure.accountNotActive),
      );
      expect(await mailTo('repo-y-$runId@example.test'), isEmpty);
      await y.client.dispose();

      // At the Auth level a deleting user CAN still link (the server does not
      // know about profiles). Recovery must still not give it access.
      final zEmail = 'repo-z-$runId@example.test';
      final raw = newClient(MemoryPkceStorage());
      final zId = (await raw.auth.signInAnonymously()).user!.id;
      track(zId);
      await raw.from('profiles').insert({
        'user_id': zId,
        'public_id': 'RZ-$runId',
        'display_name': 'Repo Z',
      });
      expect(
        await admin.rpc('begin_account_deletion', params: {'p_user_id': zId}),
        'deleting',
      );
      await raw.auth.updateUser(UserAttributes(email: zEmail));
      await raw.auth.verifyOTP(
        email: zEmail,
        token: await latestCode(zEmail),
        type: OtpType.emailChange,
      );
      await raw.auth.signOut();
      await raw.dispose();

      final f = newDevice();
      await f.repo.sendRecoveryCode(zEmail);
      final coordinator = await f.coordinator();
      await expectLater(
        coordinator.recover(email: zEmail, code: await latestCode(zEmail)),
        failsWith(EmailAuthFailure.accountNotActive),
      );
      expect(f.client.auth.currentSession, isNull);
      final state = await admin
          .from('profiles')
          .select('account_state')
          .eq('user_id', zId);
      expect(state.single['account_state'], 'deleting');
      await f.client.dispose();
    },
  );
}
