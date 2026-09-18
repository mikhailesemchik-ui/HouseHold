// Integration tests: shopping items, expenses, settlements.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'helpers.dart';

void main() {
  group('shopping items', () {
    late UserSession a;
    late UserSession b;
    late UserSession outsider;
    late String hhId;
    late String itemId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceShopping');
      b = await signInAnon(name: 'BobShopping');
      outsider = await signInAnon(name: 'Outsider');
      final hh = await createHousehold(a.client, 'ShoppingHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('A adds a shopping item', () async {
      final rows = await a.client.from('shopping_items').insert({
        'household_id': hhId,
        'name': 'Oat milk',
        'created_by': a.userId,
      }).select();
      itemId = rows.first['id'] as String;
      expect(itemId, isNotEmpty);
    });

    test('B can read the item', () async {
      final rows = await b.client
          .from('shopping_items')
          .select()
          .eq('id', itemId);
      expect(rows, hasLength(1));
      expect(rows.first['name'], equals('Oat milk'));
    });

    test('outsider cannot read the item', () async {
      final rows = await outsider.client
          .from('shopping_items')
          .select()
          .eq('id', itemId);
      expect(rows, isEmpty);
    });

    test('B completes the item', () async {
      await b.client
          .from('shopping_items')
          .update({
            'completed_at': DateTime.now().toUtc().toIso8601String(),
            'completed_by': b.userId,
          })
          .eq('id', itemId);
      final rows = await a.client
          .from('shopping_items')
          .select('completed_at, completed_by')
          .eq('id', itemId);
      expect(rows.first['completed_at'], isNotNull);
      expect(rows.first['completed_by'], equals(b.userId));
    });

    test('completing with wrong completed_by is rejected', () async {
      final rows = await a.client.from('shopping_items').insert({
        'household_id': hhId,
        'name': 'Bread',
        'created_by': a.userId,
      }).select();
      final newItemId = rows.first['id'] as String;
      expect(
        () async => a.client
            .from('shopping_items')
            .update({
              'completed_at': DateTime.now().toUtc().toIso8601String(),
              'completed_by': b.userId, // Not the authenticated user!
            })
            .eq('id', newItemId),
        throwsA(isA<PostgrestException>()),
      );
    });

    test('A reopens the item', () async {
      await a.client
          .from('shopping_items')
          .update({'completed_at': null, 'completed_by': null})
          .eq('id', itemId);
      final rows = await a.client
          .from('shopping_items')
          .select('completed_at')
          .eq('id', itemId);
      expect(rows.first['completed_at'], isNull);
    });
  });

  group('expenses — splits', () {
    late UserSession a;
    late UserSession b;
    late UserSession c;
    late UserSession outsider;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceExp');
      b = await signInAnon(name: 'BobExp');
      c = await signInAnon(name: 'CarolExp');
      outsider = await signInAnon(name: 'OutsiderExp');
      final hh = await createHousehold(a.client, 'ExpHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
      await joinByInvite(c.client, invite['code'] as String);
    });

    test('€60 split equally among A, B, C gives 2000 cents each', () async {
      await a.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hhId,
          'p_title': 'Dinner €60',
          'p_amount_cents': 6000,
          'p_currency': 'EUR',
          'p_paid_by': a.userId,
          'p_participant_ids': [a.userId, b.userId, c.userId],
        },
      );
      final expenses = await a.client
          .from('expenses')
          .select('id')
          .eq('household_id', hhId)
          .eq('title', 'Dinner €60');
      final expId = expenses.first['id'] as String;
      final parts = await a.client
          .from('expense_participants')
          .select('user_id, share_cents')
          .eq('expense_id', expId)
          .order('user_id');
      expect(parts, hasLength(3));
      final total = parts.fold<int>(0, (s, r) => s + (r['share_cents'] as int));
      expect(total, equals(6000));
      for (final r in parts) {
        expect(r['share_cents'], equals(2000));
      }
    });

    test('€40 paid by A, participants B and C only', () async {
      await a.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hhId,
          'p_title': 'Lunch €40',
          'p_amount_cents': 4000,
          'p_currency': 'EUR',
          'p_paid_by': a.userId,
          'p_participant_ids': [b.userId, c.userId],
        },
      );
      final expenses = await a.client
          .from('expenses')
          .select('id')
          .eq('household_id', hhId)
          .eq('title', 'Lunch €40');
      final expId = expenses.first['id'] as String;
      final parts = await a.client
          .from('expense_participants')
          .select()
          .eq('expense_id', expId);
      expect(parts, hasLength(2));
      // Payer (A) is not in participant list.
      final userIds = parts.map((r) => r['user_id'] as String).toSet();
      expect(userIds.contains(a.userId), isFalse);
    });

    test(
      '€10 split 3 ways: remainder goes to first, total preserved',
      () async {
        await a.client.rpc(
          'create_equal_split_expense',
          params: {
            'p_household_id': hhId,
            'p_title': 'Coffee €10',
            'p_amount_cents': 1000,
            'p_currency': 'EUR',
            'p_paid_by': a.userId,
            'p_participant_ids': [a.userId, b.userId, c.userId],
          },
        );
        final expenses = await a.client
            .from('expenses')
            .select('id')
            .eq('household_id', hhId)
            .eq('title', 'Coffee €10');
        final expId = expenses.first['id'] as String;
        final parts = await a.client
            .from('expense_participants')
            .select('share_cents')
            .eq('expense_id', expId);
        final total = parts.fold<int>(
          0,
          (s, r) => s + (r['share_cents'] as int),
        );
        expect(total, equals(1000));
        final shares = parts.map((r) => r['share_cents'] as int).toList()
          ..sort();
        // Two participants get 333, one gets 334 (remainder).
        expect(shares[0], equals(333));
        expect(shares[1], equals(333));
        expect(shares[2], equals(334));
      },
    );

    test('outsider cannot read expenses', () async {
      final rows = await outsider.client
          .from('expenses')
          .select()
          .eq('household_id', hhId);
      expect(rows, isEmpty);
    });

    test('outsider cannot call create_equal_split_expense', () async {
      expect(
        () => outsider.client.rpc(
          'create_equal_split_expense',
          params: {
            'p_household_id': hhId,
            'p_title': 'Malicious',
            'p_amount_cents': 100,
            'p_currency': 'EUR',
            'p_paid_by': outsider.userId,
            'p_participant_ids': [outsider.userId],
          },
        ),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('settlements', () {
    late UserSession a;
    late UserSession b;
    late UserSession outsider;
    late String hhId;

    setUpAll(() async {
      a = await signInAnon(name: 'AliceSettle');
      b = await signInAnon(name: 'BobSettle');
      outsider = await signInAnon(name: 'OutsiderSettle');
      final hh = await createHousehold(a.client, 'SettleHome-${uid()}');
      hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);
      // Create a debt: A pays €50, B owes €25.
      await a.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hhId,
          'p_title': 'Initial expense',
          'p_amount_cents': 5000,
          'p_currency': 'EUR',
          'p_paid_by': a.userId,
          'p_participant_ids': [a.userId, b.userId],
        },
      );
    });

    test('B records a full settlement to A', () async {
      await b.client.rpc(
        'create_settlement',
        params: {
          'p_household_id': hhId,
          'p_from_user_id': b.userId,
          'p_to_user_id': a.userId,
          'p_amount_cents': 2500,
          'p_currency': 'EUR',
        },
      );
      final rows = await a.client
          .from('expense_settlements')
          .select()
          .eq('household_id', hhId);
      expect(rows, hasLength(1));
      expect(rows.first['amount_cents'], equals(2500));
      expect(rows.first['from_user_id'], equals(b.userId));
      expect(rows.first['to_user_id'], equals(a.userId));
    });

    test('partial settlement reduces remaining correctly', () async {
      // Another expense: B pays €60, A owes €30.
      await b.client.rpc(
        'create_equal_split_expense',
        params: {
          'p_household_id': hhId,
          'p_title': 'Second expense',
          'p_amount_cents': 6000,
          'p_currency': 'EUR',
          'p_paid_by': b.userId,
          'p_participant_ids': [a.userId, b.userId],
        },
      );
      // A settles €10 partially.
      await a.client.rpc(
        'create_settlement',
        params: {
          'p_household_id': hhId,
          'p_from_user_id': a.userId,
          'p_to_user_id': b.userId,
          'p_amount_cents': 1000,
          'p_currency': 'EUR',
        },
      );
      final rows = await a.client
          .from('expense_settlements')
          .select()
          .eq('household_id', hhId)
          .eq('from_user_id', a.userId);
      expect(rows, hasLength(1));
      expect(rows.first['amount_cents'], equals(1000));
    });

    test('outsider cannot read settlements', () async {
      final rows = await outsider.client
          .from('expense_settlements')
          .select()
          .eq('household_id', hhId);
      expect(rows, isEmpty);
    });

    test('outsider cannot create a settlement', () async {
      expect(
        () => outsider.client.rpc(
          'create_settlement',
          params: {
            'p_household_id': hhId,
            'p_from_user_id': a.userId,
            'p_to_user_id': b.userId,
            'p_amount_cents': 100,
            'p_currency': 'EUR',
          },
        ),
        throwsA(isA<PostgrestException>()),
      );
    });
  });
}
