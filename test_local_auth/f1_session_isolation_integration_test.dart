// ignore_for_file: invalid_use_of_visible_for_testing_member
// REAL session-isolation checks against the ISOLATED local stack: the actual
// Realtime stream providers and repositories (not stand-ins), the real
// Supabase singleton and real RLS. Not part of `flutter test`. See
// local_stack.dart for the environment. Needs the realtime service; email
// confirmation is not required (anonymous users only).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/shopping/data/shopping_repository.dart';
import 'package:household_os/features/shopping/presentation/shopping_provider.dart';
import 'package:household_os/features/tasks/data/task_repository.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_stack.dart';

SupabaseClient get client => Supabase.instance.client;

Future<void> eventually(
  bool Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for: ${reason ?? 'condition'}');
}

int get channelCount => client.realtime.channels.length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!stackEnabled) {
    test('skipped: isolated local stack not configured', () {}, skip: true);
    return;
  }

  late SupabaseClient admin;
  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    admin = SupabaseClient(env['HH_AUTH_URL']!, env['HH_SERVICE_KEY']!);
    await Supabase.initialize(
      url: env['HH_AUTH_URL']!,
      publishableKey: env['HH_ANON_KEY']!,
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    for (final id in created) {
      try {
        await admin.auth.admin.deleteUser(id);
      } catch (_) {}
    }
    await admin.dispose();
  });

  Future<String> signInWithProfile(String tag) async {
    final id = (await client.auth.signInAnonymously()).user!.id;
    track(id);
    await client.from('profiles').insert({
      'user_id': id,
      'public_id': 'ISO$tag-$runId',
      'display_name': 'Iso $tag',
    });
    return id;
  }

  test('real stream providers: subscriptions survive a same-user refresh, are '
      'removed with the old scope, and the next user sees nothing of the '
      'previous one', () async {
    final base = channelCount;

    // ---- user A with a household, a shopping item and a task
    final aId = await signInWithProfile('A');
    final home = await client.rpc(
      'create_household',
      params: {'p_name': 'Iso'},
    );
    final h = home['id'] as String;
    await ShoppingRepository(client).addItem(householdId: h, name: 'A milk');
    await TaskRepository(client).createTask(householdId: h, title: 'A task');
    final taskId =
        (await admin.from('tasks').select('id').eq('household_id', h))
                .single['id']
            as String;

    // ---- A's scope: the real providers, each backed by a Realtime stream
    final scopeA = ProviderContainer();
    var eventsForA = 0;
    for (final p in <ProviderListenable<AsyncValue<Object?>>>[
      shoppingItemsProvider(h),
      tasksStreamProvider(h),
      expensesProvider(h),
      householdEventsStreamProvider(h),
      activeHouseholdIdsProvider,
    ]) {
      scopeA.listen(p, (_, _) => eventsForA++, fireImmediately: false);
    }
    await eventually(
      () => scopeA.read(shoppingItemsProvider(h)).hasValue,
      reason: 'A shopping stream data',
    );
    await eventually(() => channelCount > base, reason: 'channels open');
    final opened = channelCount;
    // ignore: avoid_print
    print('real channels: base=$base opened=$opened');
    expect(scopeA.read(shoppingItemsProvider(h)).value!.single.name, 'A milk');

    // The server finishes setting up its change subscriptions a moment after
    // the client reports data; an insert before that would simply be missed.
    await Future<void>.delayed(const Duration(seconds: 3));
    // ---- a live event arrives (proves Realtime delivers in this stack)
    await admin.from('shopping_items').insert({
      'household_id': h,
      'name': 'A cheese',
      'created_by': aId,
    });
    await eventually(
      () => scopeA.read(shoppingItemsProvider(h)).value!.length == 2,
      reason: 'live event before the refresh',
    );

    // ---- same-user token refresh: nothing is torn down, events still flow
    await client.auth.refreshSession();
    expect(channelCount, opened, reason: 'a refresh keeps the subscriptions');
    await admin.from('shopping_items').insert({
      'household_id': h,
      'name': 'A bread',
      'created_by': aId,
    });
    await eventually(
      () => scopeA.read(shoppingItemsProvider(h)).value!.length == 3,
      reason: 'live event after the refresh',
    );

    // ---- an A request that is already running when the user changes
    final inflight = client
        .rpc('create_household', params: {'p_name': 'Started as A'})
        .then<Object?>((v) => v);
    // ---- the identity changes: sign out, sign in as B; the root disposes A
    await client.auth.signOut(scope: SignOutScope.local);
    final bId = await signInWithProfile('B');
    scopeA.dispose();
    await eventually(
      () => channelCount == base,
      reason: 'A\'s realtime channels removed with its scope',
    );

    // A's request, started before the switch, ran as A (not as B).
    final started = await inflight as Map<String, dynamic>;
    final owner = await admin
        .from('households')
        .select('created_by')
        .eq('id', started['id'] as String);
    // ignore: avoid_print
    print(
      'in-flight request ran as: ${owner.single['created_by'] == aId ? 'A' : 'B'}',
    );
    expect(owner.single['created_by'], aId);

    // ---- B's scope: fresh subscriptions, none of A's data
    final scopeB = ProviderContainer();
    addTearDown(scopeB.dispose);
    final beforeA = eventsForA;
    scopeB.listen(shoppingItemsProvider(h), (_, _) {}, fireImmediately: false);
    scopeB.listen(householdEventsStreamProvider(h), (_, _) {});
    scopeB.listen(activeHouseholdIdsProvider, (_, _) {});
    await eventually(
      () => scopeB.read(shoppingItemsProvider(h)).hasValue,
      reason: 'B shopping stream',
    );
    expect(
      scopeB.read(shoppingItemsProvider(h)).value,
      isEmpty,
      reason: 'B is not a member of A\'s household (RLS)',
    );
    expect(
      (await scopeB.read(activeHouseholdIdsProvider.future)).contains(h),
      isFalse,
    );

    // A late change in A's household reaches neither A's disposed scope nor B.
    await admin.from('shopping_items').insert({
      'household_id': h,
      'name': 'A late',
      'created_by': aId,
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      eventsForA,
      beforeA,
      reason: 'no callback after A\'s scope was disposed',
    );
    expect(scopeB.read(shoppingItemsProvider(h)).value, isEmpty);

    // ---- requests built from A's context but sent after the switch run as B
    // and are refused by RLS: they change nothing in A's household.
    await expectLater(
      client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': h,
          'p_title': 'Stale A expense',
          'p_amount_cents': 1000,
          'p_currency': 'EUR',
          'p_paid_by': aId,
          'p_participant_ids': [aId],
        },
      ),
      throwsA(isA<PostgrestException>()),
    );
    await TaskRepository(client).completeTask(taskId); // 0 rows under B's RLS
    final task = await admin
        .from('tasks')
        .select('completed_at')
        .eq('id', taskId);
    expect(task.single['completed_at'], isNull);
    final expenses = await admin
        .from('expenses')
        .select('id')
        .eq('household_id', h);
    expect(expenses, isEmpty);
    expect(bId, isNot(aId));

    scopeB.dispose();
    await eventually(
      () => channelCount == base,
      reason: 'B\'s channels removed',
    );
  });
}
