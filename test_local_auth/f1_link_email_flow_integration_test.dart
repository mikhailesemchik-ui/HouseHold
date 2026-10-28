// ignore_for_file: invalid_use_of_visible_for_testing_member
// REAL Auth integration of the Stage 4 link-email flow (the Riverpod notifier
// the UI uses) and the sign-out/recovery journey, against the ISOLATED local
// stack only. Not part of `flutter test`. See local_stack.dart for the
// required environment; the stack must have email confirmation ON with
// code-only templates. No Auth mocks; only SharedPreferences is in memory.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/auth/presentation/link_email_flow.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_stack.dart';

Matcher failsWith(EmailAuthFailure failure) => throwsA(
  isA<EmailAuthException>().having((e) => e.failure, 'failure', failure),
);

class Device {
  Device() : client = newClient(MemoryPkceStorage()) {
    repo = EmailAccountRepository(SupabaseAuthPort(client));
  }

  final SupabaseClient client;
  late final EmailAccountRepository repo;
  final events = <String>[];
  DateTime now = DateTime(2026, 1, 1, 12);

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        emailAccountRepositoryProvider.overrideWithValue(repo),
        recoveryClockProvider.overrideWithValue(() => now),
      ],
    );
    c.listen(linkEmailFlowProvider, (_, _) {}, fireImmediately: true);
    return c;
  }

  Future<SessionSwitchCoordinator> coordinator() async {
    final prefs = await SharedPreferences.getInstance();
    return SessionSwitchCoordinator(
      repository: repo,
      marker: SessionSwitchMarker(prefs),
      unregisterPushToken: () async => events.add('unregisterPushToken'),
      restorePushRegistration: () async => events.add('restorePush'),
      clearDeviceData: () async => events.add('clearDeviceData'),
      onIdentityChanged: () => events.add('identityChanged'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!stackEnabled) {
    test('skipped: isolated local stack not configured', () {}, skip: true);
    return;
  }

  late SupabaseClient admin;
  setUpAll(() {
    HttpOverrides.global = null;
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

  Future<String> guestWithProfile(Device d, String tag) async {
    final id = (await d.client.auth.signInAnonymously()).user!.id;
    track(id);
    await d.client.from('profiles').insert({
      'user_id': id,
      'public_id': 'L$tag-$runId',
      'display_name': 'Link $tag',
    });
    return id;
  }

  test(
    'Stage 4 journey: link by notifier, same uuid, sign out, recover',
    () async {
      final users0 = await userCount(admin);
      final a = Device();
      final aId = await guestWithProfile(a, 'A');
      final hId =
          (await a.client.rpc(
                'create_household',
                params: {'p_name': 'Link S4'},
              ))['id']
              as String;
      await a.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hId,
          'p_title': 'Link dinner',
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
      final publicId = (await admin
          .from('profiles')
          .select('public_id')
          .eq('user_id', aId)
          .single())['public_id'];

      // The status the Profile shows: anonymous and unprotected.
      expect(
        protectionOf(await a.repo.currentIdentity()),
        isA<AccountUnprotected>(),
      );

      // An unlinked guest cannot sign out; nothing is touched.
      await expectLater(
        (await a.coordinator()).signOut(),
        failsWith(EmailAuthFailure.anonymousAccountAtRisk),
      );
      expect(a.client.auth.currentUser!.id, aId);
      expect(a.events, isEmpty);

      // Step 1: request a code with the notifier.
      final email = 'link-a-$runId@example.test';
      final c = a.container();
      await c.read(linkEmailFlowProvider.notifier).requestCode(email);
      expect(c.read(linkEmailFlowProvider), isA<LinkEmailCodeEntry>());
      final firstCode = await latestCode(email);

      // Pending is server state: the app can restart and resume it, and it is
      // still NOT protected.
      // A restarted app asks the server again; a fresh repository sees it.
      final pendingIdentity = await EmailAccountRepository(
        SupabaseAuthPort(a.client),
      ).currentIdentity();
      expect(protectionOf(pendingIdentity), isA<AccountVerificationPending>());
      expect(pendingIdentity.pendingEmail, email);

      // Resend is another updateUser(email); the old code stops working.
      a.now = a.now.add(recoveryResendCooldown);
      await mailApi('/api/v1/messages', method: 'DELETE');
      // The server keeps its own minimum gap between emails (5s locally).
      await Future<void>.delayed(const Duration(seconds: 6));
      await c.read(linkEmailFlowProvider.notifier).resend();
      expect(
        (c.read(linkEmailFlowProvider) as LinkEmailCodeEntry).failure,
        isNull,
      );
      final secondCode = await latestCode(email);
      expect(secondCode, isNot(firstCode));
      expect(a.client.auth.currentUser!.id, aId, reason: 'no second identity');

      await c.read(linkEmailFlowProvider.notifier).verify(firstCode);
      expect(
        (c.read(linkEmailFlowProvider) as LinkEmailCodeEntry).failure,
        EmailAuthFailure.codeRejected,
      );
      expect(
        protectionOf(await a.repo.currentIdentity()),
        isNot(isA<AccountProtected>()),
      );

      await c.read(linkEmailFlowProvider.notifier).verify('000000');
      expect(c.read(linkEmailFlowProvider), isA<LinkEmailCodeEntry>());

      await c.read(linkEmailFlowProvider.notifier).verify(secondCode);
      final done = c.read(linkEmailFlowProvider) as LinkEmailDone;
      expect(done.identity.userId, aId, reason: 'LINKED UUID == ORIGINAL UUID');
      final fresh = protectionOf(await a.repo.currentIdentity());
      expect(fresh, isA<AccountProtected>());
      expect((fresh! as AccountProtected).email, email);
      expect(
        await userCount(admin),
        users0 + 1,
        reason: 'no duplicate identity',
      );
      expect(await rowCount(admin, 'profiles'), profiles);
      expect(a.client.auth.currentUser!.id, aId);
      c.dispose();

      // A replayed code is dead, and a linked account cannot start again.
      await expectLater(
        Device().repo.verifyLinkCode(
          expectedUserId: aId,
          email: email,
          code: secondCode,
        ),
        throwsA(isA<EmailAuthException>()),
      );
      await expectLater(
        a.repo.sendLinkCode('other-$runId@example.test'),
        failsWith(EmailAuthFailure.alreadyLinked),
      );

      // Deliberate sign out through the coordinator.
      await (await a.coordinator()).signOut();
      expect(a.client.auth.currentSession, isNull);
      expect(a.events, [
        'unregisterPushToken',
        'identityChanged',
        'clearDeviceData',
      ]);
      expect(
        await userCount(admin),
        users0 + 1,
        reason: 'no guest after sign out',
      );

      // A fresh install is signed out (Welcome); recovery restores the user.
      final f = Device();
      expect(f.client.auth.currentSession, isNull);
      await f.repo.sendRecoveryCode(email);
      final code = await latestCode(email);
      final recovered = await (await f.coordinator()).recover(
        email: email,
        code: code,
      );
      expect(recovered.userId, aId, reason: 'RECOVERED UUID == ORIGINAL UUID');
      expect(await userCount(admin), users0 + 1);
      expect(await rowCount(admin, 'profiles'), profiles);
      expect(
        (await f.client
            .from('profiles')
            .select('public_id')
            .eq('user_id', aId)
            .single())['public_id'],
        publicId,
      );
      expect(
        await f.client
            .from('household_members')
            .select('user_id')
            .eq('household_id', hId)
            .eq('status', 'active'),
        hasLength(1),
      );
      expect(
        await f.client
            .from('expenses')
            .select('id, amount_cents, paid_by')
            .eq('household_id', hId),
        expensesBefore,
      );
      // ignore: avoid_print
      print(
        'original=${aId.substring(0, 8)}.. recovered=${recovered.userId.substring(0, 8)}..',
      );
      await a.client.dispose();
      await f.client.dispose();
    },
  );

  test(
    'an email that already belongs to another account is not bound',
    () async {
      final owner = Device();
      final ownerId = await guestWithProfile(owner, 'O');
      final taken = 'link-taken-$runId@example.test';
      await owner.repo.sendLinkCode(taken);
      await owner.repo.verifyLinkCode(
        expectedUserId: ownerId,
        email: taken,
        code: await latestCode(taken),
      );
      await mailApi('/api/v1/messages', method: 'DELETE');

      final d = Device();
      await guestWithProfile(d, 'B');
      final c = d.container();
      await c.read(linkEmailFlowProvider.notifier).requestCode(taken);
      expect(
        (c.read(linkEmailFlowProvider) as LinkEmailEntry).failure,
        EmailAuthFailure.emailInUse,
      );
      expect(await mailTo(taken), isEmpty);
      expect(
        protectionOf(await d.repo.currentIdentity()),
        isA<AccountUnprotected>(),
      );
      c.dispose();
      await owner.client.dispose();
      await d.client.dispose();
    },
  );
}
