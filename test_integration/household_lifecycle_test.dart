// Integration tests: household creation, invites, tasks, recurrence,
// membership removal, rejoin, and ownership transfer.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'helpers.dart';

void main() {
  group('household creation', () {
    test(
      'create_household returns household with correct name and creator',
      () async {
        final a = await signInAnon(name: 'Alice');
        final hh = await createHousehold(a.client, 'TestHome-${uid()}');
        expect(hh['id'], isNotEmpty);
        expect(hh['created_by'], equals(a.userId));
      },
    );

    test('creator becomes active owner', () async {
      final a = await signInAnon(name: 'AliceOwner');
      final hh = await createHousehold(a.client, 'OwnerHome-${uid()}');
      final hhId = hh['id'] as String;
      final rows = await a.client
          .from('household_members')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', a.userId);
      expect(rows, hasLength(1));
      expect(rows.first['role'], equals('owner'));
      expect(rows.first['status'], equals('active'));
    });

    test('membership period is opened for creator', () async {
      final a = await signInAnon(name: 'AlicePeriod');
      final hh = await createHousehold(a.client, 'PeriodHome-${uid()}');
      final hhId = hh['id'] as String;
      final svc = newServiceClient();
      final rows = await svc
          .from('household_membership_periods')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', a.userId);
      expect(rows, hasLength(1));
      expect(rows.first['left_at'], isNull);
    });

    test('blank name is rejected', () async {
      final a = await signInAnon();
      expect(
        () => createHousehold(a.client, '   '),
        throwsA(isA<PostgrestException>()),
      );
    });

    test('unauthenticated client cannot create household', () async {
      final anonClient = newClient(); // no sign-in
      expect(
        () => createHousehold(anonClient, 'ShouldFail'),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('invite flow', () {
    late UserSession a;
    late UserSession b;
    late UserSession c;
    late String hhId;
    late String inviteCode;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceInvite');
      b = await signInAnon(name: 'BobInvite');
      c = await signInAnon(name: 'CarolInvite');
      final hh = await createHousehold(a.client, 'InviteHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      inviteCode = invite['code'] as String;
    });

    test('B joins via invite and becomes active member', () async {
      await joinByInvite(b.client, inviteCode);
      final rows = await a.client
          .from('household_members')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', b.userId);
      expect(rows, hasLength(1));
      expect(rows.first['status'], equals('active'));
      expect(rows.first['role'], equals('member'));
    });

    test('B membership period is opened on join', () async {
      final svc = newServiceClient();
      final rows = await svc
          .from('household_membership_periods')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', b.userId)
          .isFilter('left_at', null);
      expect(rows, hasLength(1));
    });

    test('household is accessible to B after join', () async {
      final rows = await b.client.from('households').select().eq('id', hhId);
      expect(rows, hasLength(1));
    });

    test('duplicate join while active is idempotent, no new period', () async {
      // B is already active — joining again should return without changes.
      await joinByInvite(b.client, inviteCode);
      final svc = newServiceClient();
      final periods = await svc
          .from('household_membership_periods')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', b.userId)
          .isFilter('left_at', null);
      expect(periods, hasLength(1)); // still one open period
    });

    test('invalid invite code is rejected', () async {
      expect(
        () => joinByInvite(c.client, 'AAAA-AAAA'),
        throwsA(isA<PostgrestException>()),
      );
    });

    test('revoked invite is rejected', () async {
      final invite2 = await createInvite(a.client, hhId);
      await a.client.rpc(
        'revoke_household_invite',
        params: {'p_invite_id': invite2['id']},
      );
      expect(
        () => joinByInvite(c.client, invite2['code'] as String),
        throwsA(isA<PostgrestException>()),
      );
    });

    test('non-owner cannot create invite', () async {
      expect(
        () => createInvite(b.client, hhId),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('tasks and membership removal', () {
    late UserSession a;
    late UserSession b;
    late String hhId;
    late String taskId;
    late String occId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceTask');
      b = await signInAnon(name: 'BobTask');
      final hh = await createHousehold(a.client, 'TaskHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('A creates task assigned to B', () async {
      final due = DateTime.now().toUtc().add(const Duration(hours: 1));
      final rows = await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Sweep floor',
        'assigned_to': b.userId,
        'created_by': a.userId,
        'due_at': due.toIso8601String(),
        'recurrence_type': 'none',
      }).select();
      taskId = rows.first['id'] as String;
      expect(taskId, isNotEmpty);
    });

    test('B can read the assigned task', () async {
      final rows = await b.client.from('tasks').select().eq('id', taskId);
      expect(rows, hasLength(1));
      expect(rows.first['title'], equals('Sweep floor'));
    });

    test('task occurrence is generated for the task', () async {
      final rows = await a.client
          .from('task_occurrences')
          .select()
          .eq('task_id', taskId);
      expect(rows, hasLength(1));
      occId = rows.first['id'] as String;
    });

    test('B completes the occurrence', () async {
      await b.client.rpc(
        'complete_occurrence',
        params: {'p_occurrence_id': occId},
      );
      final rows = await b.client
          .from('task_occurrences')
          .select('completed_at, completed_by')
          .eq('id', occId);
      expect(rows.first['completed_at'], isNotNull);
      expect(rows.first['completed_by'], equals(b.userId));
    });

    test('task_event is generated for the completion', () async {
      final rows = await a.client
          .from('task_events')
          .select()
          .eq('task_id', taskId)
          .eq('event_type', 'completed');
      expect(rows, hasLength(1));
      expect(rows.first['actor_user_id'], equals(b.userId));
    });

    test('A reopens the occurrence', () async {
      await a.client.rpc(
        'reopen_occurrence',
        params: {'p_occurrence_id': occId},
      );
      final rows = await a.client
          .from('task_occurrences')
          .select('completed_at')
          .eq('id', occId);
      expect(rows.first['completed_at'], isNull);
    });

    test('reopen creates a task_event for reopened', () async {
      final rows = await a.client
          .from('task_events')
          .select()
          .eq('task_id', taskId)
          .eq('event_type', 'reopened');
      expect(rows, isNotEmpty);
    });

    test('A removes B from household', () async {
      await a.client.rpc(
        'remove_household_member',
        params: {'p_household_id': hhId, 'p_user_id': b.userId},
      );
      final rows = await a.client
          .from('household_members')
          .select('status')
          .eq('household_id', hhId)
          .eq('user_id', b.userId);
      expect(rows.first['status'], equals('left'));
    });

    test('membership period is closed after removal', () async {
      final svc = newServiceClient();
      final rows = await svc
          .from('household_membership_periods')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', b.userId)
          .isFilter('left_at', null);
      expect(rows, isEmpty);
    });

    test('B loses household access after removal', () async {
      final rows = await b.client
          .from('tasks')
          .select()
          .eq('household_id', hhId);
      expect(rows, isEmpty);
    });

    test('future incomplete task assignments to B are cleared', () async {
      // Re-insert a future task assigned to B before removal would have cleared it.
      // Since removal already happened, verify via the task we created earlier.
      final rows = await a.client
          .from('tasks')
          .select('assigned_to')
          .eq('id', taskId);
      // Task assigned_to should be null since B was removed.
      expect(rows.first['assigned_to'], isNull);
    });
  });

  group('rejoin after removal', () {
    late UserSession a;
    late UserSession b;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceRejoin');
      b = await signInAnon(name: 'BobRejoin');
      final hh = await createHousehold(a.client, 'RejoinHome-${uid()}');
      hhId = hh['id'] as String;
      final inv1 = await createInvite(a.client, hhId);
      await joinByInvite(b.client, inv1['code'] as String);
      await a.client.rpc(
        'remove_household_member',
        params: {'p_household_id': hhId, 'p_user_id': b.userId},
      );
    });

    test('B rejoins with a new invite', () async {
      final inv2 = await createInvite(a.client, hhId);
      await joinByInvite(b.client, inv2['code'] as String);
      final rows = await a.client
          .from('household_members')
          .select('status, role')
          .eq('household_id', hhId)
          .eq('user_id', b.userId);
      expect(rows.first['status'], equals('active'));
      expect(rows.first['role'], equals('member'));
    });

    test('B has the same auth identity and profile after rejoin', () async {
      final rows = await b.client
          .from('profiles')
          .select()
          .eq('user_id', b.userId);
      expect(rows, hasLength(1));
      expect(rows.first['display_name'], equals('BobRejoin'));
    });

    test('a new open membership period is created on rejoin', () async {
      final svc = newServiceClient();
      final rows = await svc
          .from('household_membership_periods')
          .select()
          .eq('household_id', hhId)
          .eq('user_id', b.userId)
          .isFilter('left_at', null);
      expect(rows, hasLength(1));
    });

    test(
      'historical periods from the first membership are preserved',
      () async {
        final svc = newServiceClient();
        final rows = await svc
            .from('household_membership_periods')
            .select()
            .eq('household_id', hhId)
            .eq('user_id', b.userId);
        expect(rows.length, greaterThanOrEqualTo(2));
      },
    );
  });

  group('ownership transfer', () {
    late UserSession a;
    late UserSession b;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceOwnership');
      b = await signInAnon(name: 'BobOwnership');
      final hh = await createHousehold(a.client, 'OwnershipHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('A transfers ownership to B', () async {
      await a.client.rpc(
        'transfer_household_ownership',
        params: {'p_household_id': hhId, 'p_new_owner_id': b.userId},
      );
      final rows = await a.client
          .from('household_members')
          .select('user_id, role')
          .eq('household_id', hhId)
          .inFilter('user_id', [a.userId, b.userId]);
      final map = {for (final r in rows) r['user_id'] as String: r['role']};
      expect(map[b.userId], equals('owner'));
      expect(map[a.userId], equals('member'));
    });

    test('former owner A can leave after transfer', () async {
      await a.client.rpc('leave_household', params: {'p_household_id': hhId});
      final rows = await b.client
          .from('household_members')
          .select('status')
          .eq('household_id', hhId)
          .eq('user_id', a.userId);
      expect(rows.first['status'], equals('left'));
    });

    test('only owner can transfer ownership', () async {
      // A is now a left member, B is owner. C tries to transfer — should fail.
      final c = await signInAnon(name: 'CarolOwnership');
      expect(
        () => c.client.rpc(
          'transfer_household_ownership',
          params: {'p_household_id': hhId, 'p_new_owner_id': b.userId},
        ),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('recurrence', () {
    late UserSession a;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceRecur');
      final hh = await createHousehold(a.client, 'RecurHome-${uid()}');
      hhId = hh['id'] as String;
    });

    test('daily task generates 30 occurrences', () async {
      final due = DateTime.now().toUtc();
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Daily task',
        'created_by': a.userId,
        'due_at': due.toIso8601String(),
        'recurrence_type': 'daily',
      });
      // Trigger generation
      await a.client.rpc('refresh_my_recurring_occurrences');
      final tasks = await a.client
          .from('tasks')
          .select('id')
          .eq('household_id', hhId)
          .eq('recurrence_type', 'daily');
      final taskId = tasks.first['id'] as String;
      final rows = await a.client
          .from('task_occurrences')
          .select()
          .eq('task_id', taskId);
      expect(rows.length, equals(30));
    });

    test('weekly task generates 12 occurrences', () async {
      final due = DateTime.now().toUtc();
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Weekly task',
        'created_by': a.userId,
        'due_at': due.toIso8601String(),
        'recurrence_type': 'weekly',
      });
      await a.client.rpc('refresh_my_recurring_occurrences');
      final tasks = await a.client
          .from('tasks')
          .select('id')
          .eq('household_id', hhId)
          .eq('recurrence_type', 'weekly');
      final taskId = tasks.first['id'] as String;
      final rows = await a.client
          .from('task_occurrences')
          .select()
          .eq('task_id', taskId);
      expect(rows.length, equals(12));
    });

    test('refresh_my_recurring_occurrences is idempotent', () async {
      // Run again — count must not increase.
      await a.client.rpc('refresh_my_recurring_occurrences');
      final tasks = await a.client
          .from('tasks')
          .select('id')
          .eq('household_id', hhId)
          .eq('recurrence_type', 'daily');
      final taskId = tasks.first['id'] as String;
      final rows = await a.client
          .from('task_occurrences')
          .select()
          .eq('task_id', taskId);
      expect(rows.length, equals(30));
    });

    test('completing one occurrence does not complete others', () async {
      final tasks = await a.client
          .from('tasks')
          .select('id')
          .eq('household_id', hhId)
          .eq('recurrence_type', 'daily');
      final taskId = tasks.first['id'] as String;
      final occs = await a.client
          .from('task_occurrences')
          .select('id')
          .eq('task_id', taskId)
          .order('scheduled_at');
      final firstId = occs.first['id'] as String;
      await a.client.rpc(
        'complete_occurrence',
        params: {'p_occurrence_id': firstId},
      );
      final remaining = await a.client
          .from('task_occurrences')
          .select()
          .eq('task_id', taskId)
          .isFilter('completed_at', null);
      expect(remaining.length, equals(29));
    });
  });
}
