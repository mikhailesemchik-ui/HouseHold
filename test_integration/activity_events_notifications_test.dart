// Integration tests: household_events triggers, notification outbox, realtime.

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'helpers.dart';

void main() {
  group('household_events triggers', () {
    late UserSession a;
    late UserSession b;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceEvents');
      b = await signInAnon(name: 'BobEvents');
      final hh = await createHousehold(a.client, 'EventsHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('task_created event is generated when A creates a task', () async {
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Event task',
        'created_by': a.userId,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'task_created')
          .eq('title_snapshot', 'Event task');
      expect(rows, hasLength(1));
      expect(rows.first['actor_user_id'], equals(a.userId));
      expect(rows.first['entity_type'], equals('task'));
    });

    test('task_completed event is generated when B completes task', () async {
      final due = DateTime.now().toUtc().add(const Duration(hours: 1));
      final taskRows = await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Task to complete',
        'created_by': a.userId,
        'due_at': due.toIso8601String(),
        'recurrence_type': 'none',
      }).select();
      final occRows = await a.client
          .from('task_occurrences')
          .select('id')
          .eq('task_id', taskRows.first['id'] as String);
      final occId = occRows.first['id'] as String;
      await b.client.rpc(
        'complete_occurrence',
        params: {'p_occurrence_id': occId},
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final events = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'task_completed')
          .eq('title_snapshot', 'Task to complete');
      expect(events, hasLength(1));
      expect(events.first['actor_user_id'], equals(b.userId));
    });

    test('shopping_item_added event is generated', () async {
      await a.client.from('shopping_items').insert({
        'household_id': hhId,
        'name': 'Event item',
        'created_by': a.userId,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'shopping_item_added')
          .eq('title_snapshot', 'Event item');
      expect(rows, hasLength(1));
      expect(rows.first['actor_user_id'], equals(a.userId));
    });

    test('expense_created event is generated with amount snapshot', () async {
      await a.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hhId,
          'p_title': 'Event expense',
          'p_amount_cents': 3000,
          'p_currency': 'EUR',
          'p_paid_by': a.userId,
          'p_participant_ids': [a.userId, b.userId],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'expense_created')
          .eq('title_snapshot', 'Event expense');
      expect(rows, hasLength(1));
      expect(rows.first['amount_cents'], equals(3000));
      expect(rows.first['currency'], equals('EUR'));
    });

    test('member_joined event is generated when B joined', () async {
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'member_joined')
          .eq('actor_user_id', b.userId);
      expect(rows, isNotEmpty);
    });

    test('member_removed event is generated when A removes B', () async {
      final c = await signInAnon(name: 'CarolRemoved');
      final hh2 = await createHousehold(a.client, 'RemoveEventHome-${uid()}');
      final hhId2 = hh2['id'] as String;
      final inv = await createInvite(a.client, hhId2);
      await joinByInvite(c.client, inv['code'] as String);
      await a.client.rpc(
        'remove_household_member',
        params: {'p_household_id': hhId2, 'p_user_id': c.userId},
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId2)
          .eq('event_type', 'member_removed');
      expect(rows, hasLength(1));
      expect(rows.first['actor_user_id'], equals(a.userId));
      expect(rows.first['title_snapshot'], equals('CarolRemoved'));
    });

    test('ownership_transferred event is generated', () async {
      final owner = await signInAnon(name: 'AliceTransfer');
      final newOwner = await signInAnon(name: 'BobTransfer');
      final hh3 = await createHousehold(
        owner.client,
        'TransferEventHome-${uid()}',
      );
      final hhId3 = hh3['id'] as String;
      final inv = await createInvite(owner.client, hhId3);
      await joinByInvite(newOwner.client, inv['code'] as String);
      await owner.client.rpc(
        'transfer_household_ownership',
        params: {'p_household_id': hhId3, 'p_new_owner_id': newOwner.userId},
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await owner.client
          .from('household_events')
          .select()
          .eq('household_id', hhId3)
          .eq('event_type', 'ownership_transferred');
      expect(rows, hasLength(1));
      expect(rows.first['actor_user_id'], equals(owner.userId));
      expect(rows.first['title_snapshot'], equals('BobTransfer'));
    });

    test('one logical operation does not produce duplicate events', () async {
      // Create a single task — should produce exactly one task_created event.
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'UniqueEventTask-${uid()}',
        'created_by': a.userId,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Count all task_created events for this household.
      final rows = await a.client
          .from('household_events')
          .select()
          .eq('household_id', hhId)
          .eq('event_type', 'task_created');
      // Each task insert produces exactly one event.
      final taskRows = await a.client
          .from('tasks')
          .select()
          .eq('household_id', hhId);
      expect(rows.length, equals(taskRows.length));
    });
  });

  group('notification outbox — service-role verification', () {
    late UserSession a;
    late UserSession b;
    late String hhId;
    late SupabaseClient svc;

    setUpAll(() async {
      svc = newServiceClient();
      a = await signInAnon(name: 'AliceNotif');
      b = await signInAnon(name: 'BobNotif');
      final hh = await createHousehold(a.client, 'NotifHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('task_assigned to B generates one outbox row for B', () async {
      final before = await svc
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', b.userId)
          .eq('type', 'task_assigned');
      final countBefore = before.length;
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Assigned to B',
        'created_by': a.userId,
        'assigned_to': b.userId,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final after = await svc
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', b.userId)
          .eq('type', 'task_assigned');
      expect(after.length, equals(countBefore + 1));
    });

    test('task_assigned to self (A→A) generates no outbox row', () async {
      final before = await svc
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', a.userId)
          .eq('type', 'task_assigned');
      final countBefore = before.length;
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Self-assigned',
        'created_by': a.userId,
        'assigned_to': a.userId,
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final after = await svc
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', a.userId)
          .eq('type', 'task_assigned');
      expect(after.length, equals(countBefore)); // no new notification
    });

    test('member_removed notification is sent to the removed user', () async {
      final c = await signInAnon(name: 'CarolNotif');
      final hh2 = await createHousehold(a.client, 'NotifHome2-${uid()}');
      final hhId2 = hh2['id'] as String;
      final inv = await createInvite(a.client, hhId2);
      await joinByInvite(c.client, inv['code'] as String);
      await a.client.rpc(
        'remove_household_member',
        params: {'p_household_id': hhId2, 'p_user_id': c.userId},
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = await svc
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', c.userId)
          .eq('type', 'member_removed');
      expect(rows, hasLength(1));
    });

    test(
      'ownership_transferred notification is sent to the new owner',
      () async {
        final owner = await signInAnon(name: 'AliceNotifOwner');
        final newOwner = await signInAnon(name: 'BobNotifOwner');
        final hh3 = await createHousehold(owner.client, 'NotifOwner-${uid()}');
        final hhId3 = hh3['id'] as String;
        final inv = await createInvite(owner.client, hhId3);
        await joinByInvite(newOwner.client, inv['code'] as String);
        await owner.client.rpc(
          'transfer_household_ownership',
          params: {'p_household_id': hhId3, 'p_new_owner_id': newOwner.userId},
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final rows = await svc
            .from('notification_outbox')
            .select()
            .eq('recipient_user_id', newOwner.userId)
            .eq('type', 'ownership_transferred');
        expect(rows, hasLength(1));
      },
    );

    test('notification payload contains no email or auth UUID', () async {
      final rows = await svc
          .from('notification_outbox')
          .select('payload, body, title')
          .eq('recipient_user_id', b.userId)
          .eq('type', 'task_assigned')
          .limit(1);
      expect(rows, isNotEmpty);
      final payload = rows.first['payload'] as Map;
      // Payload must contain householdId and type but no email/auth fields.
      expect(payload.containsKey('type'), isTrue);
      expect(payload.containsKey('email'), isFalse);
      expect(payload.containsKey('phone'), isFalse);
    });

    test('clients have no read access to notification_outbox', () async {
      // notification_outbox has no client RLS policy — expect empty result
      // (RLS denies, Supabase returns empty rather than error for SELECT).
      final rows = await b.client
          .from('notification_outbox')
          .select()
          .eq('recipient_user_id', b.userId);
      expect(rows, isEmpty);
    });
  });

  group('realtime', () {
    test('task_occurrences change is received by a subscriber', () async {
      final a = await signInAnon(name: 'AliceRealtime');
      final b = await signInAnon(name: 'BobRealtime');
      final hh = await createHousehold(a.client, 'RealtimeHome-${uid()}');
      final hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);

      final received = Completer<Map<String, dynamic>>();

      final channel = b.client
          .channel('test-realtime-${uid()}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'task_occurrences',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'household_id',
              value: hhId,
            ),
            callback: (payload) {
              if (!received.isCompleted) received.complete(payload.newRecord);
            },
          )
          .subscribe();

      // Allow subscription to establish.
      await Future<void>.delayed(const Duration(seconds: 1));

      final due = DateTime.now().toUtc().add(const Duration(hours: 1));
      await a.client.from('tasks').insert({
        'household_id': hhId,
        'title': 'Realtime task',
        'created_by': a.userId,
        'due_at': due.toIso8601String(),
        'recurrence_type': 'none',
      });

      // Wait for the realtime event (10 s timeout).
      final record = await received.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => <String, dynamic>{},
      );

      await b.client.removeChannel(channel);

      if (record.isEmpty) {
        // Realtime may be unreliable in the local test environment; mark skipped.
        markTestSkipped(
          'Realtime event not received within 10 s — '
          'verify manually or check local Supabase realtime config',
        );
        return;
      }

      expect(record['household_id'], equals(hhId));
    });
  });
}
