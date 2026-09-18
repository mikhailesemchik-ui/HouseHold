// Integration tests: anonymous auth, profiles, and RLS isolation.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'helpers.dart';

void main() {
  group('anonymous auth', () {
    test('signInAnonymously returns a valid user', () async {
      final a = await signInAnon(name: 'UserA');
      expect(a.userId, isNotEmpty);
      expect(a.client.auth.currentUser?.id, equals(a.userId));
    });

    test('three anonymous users receive distinct UIDs', () async {
      final a = await signInAnon();
      final b = await signInAnon();
      final c = await signInAnon();
      expect(a.userId, isNot(equals(b.userId)));
      expect(b.userId, isNot(equals(c.userId)));
      expect(a.userId, isNot(equals(c.userId)));
    });

    test('profile row is created with public_id and display_name', () async {
      final a = await signInAnon(name: 'TestAlice');
      final rows = await a.client
          .from('profiles')
          .select()
          .eq('user_id', a.userId);
      expect(rows, hasLength(1));
      final p = rows.first;
      expect(p['public_id'], isNotEmpty);
      expect(p['display_name'], equals('TestAlice'));
      expect(p['user_id'], equals(a.userId));
    });

    test('public_id is not the raw auth UUID', () async {
      final a = await signInAnon();
      final rows = await a.client
          .from('profiles')
          .select('public_id')
          .eq('user_id', a.userId);
      final publicId = rows.first['public_id'] as String;
      expect(publicId, isNot(equals(a.userId)));
      // Public ID format: XXXX-XXXX (alphanumeric, no UUID hyphens in first segment)
      expect(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(publicId), isTrue);
    });
  });

  group('profile RLS', () {
    test('user can read their own profile', () async {
      final a = await signInAnon(name: 'CanReadOwn');
      final rows = await a.client
          .from('profiles')
          .select()
          .eq('user_id', a.userId);
      expect(rows, hasLength(1));
      expect(rows.first['display_name'], equals('CanReadOwn'));
    });

    test('user can update their own display_name', () async {
      final a = await signInAnon(name: 'OldName');
      await a.client
          .from('profiles')
          .update({'display_name': 'NewName'})
          .eq('user_id', a.userId);
      final rows = await a.client
          .from('profiles')
          .select('display_name')
          .eq('user_id', a.userId);
      expect(rows.first['display_name'], equals('NewName'));
    });

    test('user B cannot update user A profile', () async {
      final a = await signInAnon(name: 'Alice');
      final b = await signInAnon(name: 'Bob');
      // B tries to mutate A's display_name — should affect 0 rows due to RLS.
      await b.client
          .from('profiles')
          .update({'display_name': 'Hacked'})
          .eq('user_id', a.userId);
      // Verify A's name is unchanged from A's own client.
      final rows = await a.client
          .from('profiles')
          .select('display_name')
          .eq('user_id', a.userId);
      expect(rows.first['display_name'], equals('Alice'));
    });

    test(
      'non-member B cannot read A profile before sharing a household',
      () async {
        final a = await signInAnon(name: 'Alice');
        final b = await signInAnon(name: 'Bob');
        // No shared household, so B cannot see A.
        final rows = await b.client
            .from('profiles')
            .select()
            .eq('user_id', a.userId);
        expect(rows, isEmpty);
      },
    );

    test('co-member can read each other profiles', () async {
      final a = await signInAnon(name: 'AliceProfile');
      final b = await signInAnon(name: 'BobProfile');
      final hh = await createHousehold(a.client, 'ProfileHome-${uid()}');
      final hhId = hh['id'] as String;
      final invite = await createInvite(a.client, hhId);
      await joinByInvite(b.client, invite['code'] as String);

      // B can now read A's profile.
      final rowsB = await b.client
          .from('profiles')
          .select('display_name')
          .eq('user_id', a.userId);
      expect(rowsB, hasLength(1));
      expect(rowsB.first['display_name'], equals('AliceProfile'));

      // A can also read B's profile.
      final rowsA = await a.client
          .from('profiles')
          .select('display_name')
          .eq('user_id', b.userId);
      expect(rowsA, hasLength(1));
      expect(rowsA.first['display_name'], equals('BobProfile'));
    });
  });

  group('cross-household RLS isolation', () {
    late UserSession a;
    late UserSession b;
    late String hhAId; // A's private household (B is not a member)
    late String hhBId; // Shared household (both are members)

    setUpAll(() async {
      a = await signInAnon(name: 'AliceRLS');
      b = await signInAnon(name: 'BobRLS');

      final hhA = await createHousehold(a.client, 'PrivateHome-${uid()}');
      hhAId = hhA['id'] as String;
      // A creates a task in the private household.
      await a.client.from('tasks').insert({
        'household_id': hhAId,
        'title': 'Private task',
        'created_by': a.userId,
      });

      final hhB = await createHousehold(a.client, 'SharedHome-${uid()}');
      hhBId = hhB['id'] as String;
      final invite = await createInvite(a.client, hhBId);
      await joinByInvite(b.client, invite['code'] as String);
    });

    test('B cannot read tasks from a household B is not a member of', () async {
      final rows = await b.client
          .from('tasks')
          .select()
          .eq('household_id', hhAId);
      expect(rows, isEmpty);
    });

    test('B cannot read shopping items from private household', () async {
      await a.client.from('shopping_items').insert({
        'household_id': hhAId,
        'name': 'Secret item',
        'created_by': a.userId,
      });
      final rows = await b.client
          .from('shopping_items')
          .select()
          .eq('household_id', hhAId);
      expect(rows, isEmpty);
    });

    test('B cannot read expenses from private household', () async {
      final rows = await b.client
          .from('expenses')
          .select()
          .eq('household_id', hhAId);
      expect(rows, isEmpty);
    });

    test('B cannot read household_events from private household', () async {
      final rows = await b.client
          .from('household_events')
          .select()
          .eq('household_id', hhAId);
      expect(rows, isEmpty);
    });

    test('B cannot read household_members from private household', () async {
      final rows = await b.client
          .from('household_members')
          .select()
          .eq('household_id', hhAId);
      expect(rows, isEmpty);
    });

    test('B cannot self-promote to owner via direct update', () async {
      // Direct update bypassed by RLS — should affect 0 rows
      await b.client
          .from('household_members')
          .update({'role': 'owner'})
          .eq('household_id', hhBId)
          .eq('user_id', b.userId);
      // Verify B is still a member (read from A's client).
      final rows = await a.client
          .from('household_members')
          .select('role')
          .eq('household_id', hhBId)
          .eq('user_id', b.userId);
      expect(rows.first['role'], equals('member'));
    });

    test('B cannot insert tasks into private household', () async {
      try {
        await b.client.from('tasks').insert({
          'household_id': hhAId,
          'title': 'Malicious task',
          'created_by': b.userId,
        });
        fail('should have thrown');
      } on PostgrestException {
        // Expected: RLS blocks insert
      }
    });

    test('B can read tasks from the shared household', () async {
      await a.client.from('tasks').insert({
        'household_id': hhBId,
        'title': 'Shared task',
        'created_by': a.userId,
      });
      final rows = await b.client
          .from('tasks')
          .select()
          .eq('household_id', hhBId)
          .eq('title', 'Shared task');
      expect(rows, hasLength(1));
    });
  });
}
