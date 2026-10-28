// ignore_for_file: invalid_use_of_visible_for_testing_member
// REAL integration of the F1 Stage 3 startup gate and recovery flow: the real
// Supabase singleton, the real providers (startupProvider, recoveryFlowProvider)
// and the ISOLATED local Auth stack. Not part of `flutter test`. See
// local_stack.dart / f1_sdk_verification_test.dart for the environment and the
// required stack configuration (email confirmations ON, code templates, mail
// capture). Only SharedPreferences uses in-memory values.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/startup/domain/startup_state.dart';
import 'package:household_os/features/startup/presentation/startup_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_stack.dart';

Future<void> initSupabase() => Supabase.initialize(
  url: env['HH_AUTH_URL']!,
  publishableKey: env['HH_ANON_KEY']!,
  authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
);

/// Simulates killing and relaunching the app: preferences (and so the
/// persisted session) survive, everything in memory is rebuilt.
Future<void> relaunch() async {
  await Supabase.instance.dispose();
  await initSupabase();
}

ProviderContainer newApp() {
  final container = ProviderContainer(retry: (_, _) => null);
  container.listen(startupProvider, (_, _) {}, fireImmediately: true);
  container.listen(recoveryFlowProvider, (_, _) {}, fireImmediately: true);
  return container;
}

Future<StartupState> startupSettled(
  ProviderContainer c, {
  List<StartupState>? seen,
}) async {
  c.listen(startupProvider, (_, next) => seen?.add(next));
  for (var i = 0; i < 100; i++) {
    final s = c.read(startupProvider);
    if (s is! StartupResolving && s is! StartupSigningIn) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('startup did not settle');
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

  /// An email-linked account with a profile and a household, created through
  /// the F1 repository, then signed out (a user on another device).
  Future<(String, String, String)> linkedAccount(String tag) async {
    final client = newClient(MemoryPkceStorage());
    final repo = EmailAccountRepository(SupabaseAuthPort(client));
    final id = (await client.auth.signInAnonymously()).user!.id;
    track(id);
    final publicId = 'S3$tag-$runId';
    await client.from('profiles').insert({
      'user_id': id,
      'public_id': publicId,
      'display_name': 'Stage3 $tag',
    });
    final household = await client.rpc(
      'create_household',
      params: {'p_name': 'Stage3 $tag'},
    );
    final email = 's3-${tag.toLowerCase()}-$runId@example.test';
    await repo.sendLinkCode(email);
    await repo.verifyLinkCode(
      expectedUserId: id,
      email: email,
      code: await latestCode(email),
    );
    await client.auth.signOut();
    await client.dispose();
    await mailApi('/api/v1/messages', method: 'DELETE');
    return (id, email, '$publicId|${household['id']}');
  }

  test(
    'fresh install: welcome first, nothing created; Get started creates '
    'exactly one anonymous user; a relaunch resumes it without a welcome',
    () async {
      final users0 = await userCount(admin);
      await initSupabase();
      expect(Supabase.instance.client.auth.currentSession, isNull);

      var app = newApp();
      expect(await startupSettled(app), isA<StartupWelcome>());
      expect(
        await userCount(admin),
        users0,
        reason: 'no guest before the choice',
      );

      await app.read(startupProvider.notifier).continueWithoutRegistration();
      final ready = app.read(startupProvider) as StartupReady;
      final userId = Supabase.instance.client.auth.currentUser!.id;
      track(userId);
      expect(ready.profile.userId, userId);
      expect(await userCount(admin), users0 + 1);
      app.dispose();

      await relaunch();
      app = newApp();
      final seen = <StartupState>[];
      final state = await startupSettled(app, seen: seen);
      expect(state, isA<StartupReady>());
      expect(
        seen.whereType<StartupWelcome>(),
        isEmpty,
        reason: 'no welcome flash',
      );
      expect(Supabase.instance.client.auth.currentUser!.id, userId);
      expect(
        await userCount(admin),
        users0 + 1,
        reason: 'the session was resumed',
      );
      app.dispose();
      await Supabase.instance.dispose();
    },
  );

  test('recovery on a fresh install restores the SAME uuid, profile and '
      'household, and creates no guest account', () async {
    final (accountId, email, extra) = await linkedAccount('A');
    final publicId = extra.split('|').first;
    final householdId = extra.split('|').last;
    final users0 = await userCount(admin);

    await initSupabase(); // a "reinstalled" app: empty preferences, no session
    var app = newApp();
    expect(await startupSettled(app), isA<StartupWelcome>());

    final flow = app.read(recoveryFlowProvider.notifier);
    await flow.requestCode(email);
    expect(app.read(recoveryFlowProvider), isA<RecoveryCodeEntry>());
    await flow.verify(await latestCode(email));
    final done = app.read(recoveryFlowProvider);
    expect(done, isA<RecoverySucceeded>());
    expect((done as RecoverySucceeded).identity.userId, accountId);
    // ignore: avoid_print
    print(
      'original=${accountId.substring(0, 8)}.. '
      'recovered=${Supabase.instance.client.auth.currentUser!.id.substring(0, 8)}..',
    );
    expect(Supabase.instance.client.auth.currentUser!.id, accountId);
    expect(await userCount(admin), users0, reason: 'no new Auth user at all');
    app.dispose();

    // What the user-scoped root does on the id change: a fresh app scope.
    app = newApp();
    final ready = await startupSettled(app);
    expect(ready, isA<StartupReady>());
    expect((ready as StartupReady).profile.publicId, publicId);
    final members = await Supabase.instance.client
        .from('household_members')
        .select('user_id')
        .eq('household_id', householdId)
        .eq('status', 'active');
    expect(members, hasLength(1));
    expect(await userCount(admin), users0);
    app.dispose();
    await Supabase.instance.dispose();
  });

  test(
    'an unknown email looks the same, creates nobody and cannot sign in',
    () async {
      final users0 = await userCount(admin);
      await initSupabase();
      final app = newApp();
      expect(await startupSettled(app), isA<StartupWelcome>());
      final flow = app.read(recoveryFlowProvider.notifier);
      final unknown = 's3-nobody-$runId@example.test';
      await flow.requestCode(unknown);
      expect(app.read(recoveryFlowProvider), isA<RecoveryCodeEntry>());
      expect(await mailTo(unknown), isEmpty);
      await flow.verify('123456');
      final s = app.read(recoveryFlowProvider) as RecoveryCodeEntry;
      expect(s.failure, EmailAuthFailure.codeRejected);
      expect(Supabase.instance.client.auth.currentSession, isNull);
      expect(await userCount(admin), users0);
      app.dispose();
      await Supabase.instance.dispose();
    },
  );

  test('recovery is refused while a guest account is signed in', () async {
    final (_, email, _) = await linkedAccount('B');
    await initSupabase();
    var app = newApp();
    await startupSettled(app);
    await app.read(startupProvider.notifier).continueWithoutRegistration();
    final guestId = Supabase.instance.client.auth.currentUser!.id;
    track(guestId);
    app.dispose();
    app = newApp();
    final flow = app.read(recoveryFlowProvider.notifier);
    await flow.requestCode(email);
    await flow.verify(await latestCode(email));
    final s = app.read(recoveryFlowProvider) as RecoveryCodeEntry;
    expect(s.failure, EmailAuthFailure.anonymousAccountAtRisk);
    expect(
      Supabase.instance.client.auth.currentUser!.id,
      guestId,
      reason: 'the guest account was not silently replaced',
    );
    app.dispose();
    await Supabase.instance.dispose();
  });

  test('a pending account-deletion cleanup is finished BEFORE the welcome '
      'choice, touching only that user\'s financial request ids', () async {
    SharedPreferences.setMockInitialValues({
      'account_deletion_attempt_user': 'user-gone',
      'pending_financial_op/expense/user-gone/hh-1': '[{"id":"a","hash":"h"}]',
      'pending_financial_op/expense/user-keep/hh-1': '[{"id":"b","hash":"h"}]',
      'widget_privacy_mode': 'show_names',
    });
    final users0 = await userCount(admin);
    await initSupabase();
    final app = newApp();
    expect(await startupSettled(app), isA<StartupWelcome>());

    final prefs = await SharedPreferences.getInstance();
    final store = FinancialRequestStore(prefs);
    expect(prefs.getString('account_deletion_attempt_user'), isNull);
    expect(
      store.pending(userId: 'user-gone', householdId: 'hh-1', kind: 'expense'),
      isEmpty,
    );
    expect(
      store.pending(userId: 'user-keep', householdId: 'hh-1', kind: 'expense'),
      hasLength(1),
    );
    expect(prefs.getString('widget_privacy_mode'), 'show_names');
    expect(await userCount(admin), users0);
    app.dispose();
    await Supabase.instance.dispose();
  });

  test('real auth events: a refresh or profile update repeats the user id '
      '(root scope kept); only sign-in and sign-out change it', () async {
    await initSupabase();
    final ids = <String?>[];
    final sub = Supabase.instance.client.auth.onAuthStateChange
        .map((s) => s.session?.user.id)
        .listen(ids.add);
    final auth = Supabase.instance.client.auth;
    final id = (await auth.signInAnonymously()).user!.id;
    track(id);
    await auth.refreshSession();
    await auth.updateUser(UserAttributes(data: {'tag': 'x'}));
    await auth.signOut(scope: SignOutScope.local);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    final changes = <String?>[];
    for (final v in ids) {
      if (changes.isEmpty || changes.last != v) changes.add(v);
    }
    // ignore: avoid_print
    print('raw auth events: ${ids.length}, distinct user-id changes: $changes');
    expect(ids.length, greaterThan(changes.length), reason: 'repeats exist');
    expect(changes.where((v) => v != null), everyElement(id));
    expect(changes.last, isNull);
    await Supabase.instance.dispose();
  });
}
