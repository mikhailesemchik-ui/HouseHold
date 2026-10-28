import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/startup/data/startup_port.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_startup_port.dart';

const _deleted = 'user-deleted';
const _other = 'user-other';

SupabaseStartupPort _port(List<String> cleared, {bool failClear = false}) {
  // A client with no session and nothing listening: it must never be called.
  final client = SupabaseClient('http://127.0.0.1:1', 'anon-key');
  return SupabaseStartupPort(
    client,
    loadProfile: () async => fakeStartupProfile(),
    clearDeviceData: () async {
      cleared.add('clear');
      if (failClear) throw StateError('device cleanup failed');
    },
  );
}

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues({
    'pending_financial_op/expense/$_deleted/hh-1': '[{"id":"a","hash":"h1"}]',
    'pending_financial_op/expense/$_other/hh-1': '[{"id":"b","hash":"h2"}]',
    'widget_privacy_mode': 'show_names',
    ...values,
  });
  return SharedPreferences.getInstance();
}

void main() {
  test('no session, no markers: nothing to do and nothing created', () async {
    final prefs = await _prefs({});
    final cleared = <String>[];
    final port = _port(cleared);
    expect(port.hasSession, isFalse);
    await port.resumePendingCleanup();
    expect(cleared, isEmpty);
    expect(prefs.getKeys().length, 3);
  });

  test(
    'an interrupted deletion is finished: only that user\'s pending financial '
    'requests go, the marker is removed, settings stay',
    () async {
      final prefs = await _prefs({'account_deletion_attempt_user': _deleted});
      final cleared = <String>[];
      await _port(cleared).resumePendingCleanup();

      final store = FinancialRequestStore(prefs);
      expect(
        store.pending(userId: _deleted, householdId: 'hh-1', kind: 'expense'),
        isEmpty,
      );
      expect(
        store.pending(userId: _other, householdId: 'hh-1', kind: 'expense'),
        hasLength(1),
        reason: 'another user\'s request ids are never touched',
      );
      expect(prefs.getString('account_deletion_attempt_user'), isNull);
      expect(prefs.getString('widget_privacy_mode'), 'show_names');
      expect(cleared, ['clear']);
    },
  );

  test(
    'an interrupted user switch cleans the previous user\'s device state and '
    'leaves the deletion marker and financial ids alone',
    () async {
      final prefs = await _prefs({'session_switch_from_user': 'user-prev'});
      final cleared = <String>[];
      await _port(cleared).resumePendingCleanup();
      expect(cleared, ['clear']);
      expect(prefs.getString('session_switch_from_user'), isNull);
      final store = FinancialRequestStore(prefs);
      expect(
        store.pending(userId: _deleted, householdId: 'hh-1', kind: 'expense'),
        hasLength(1),
      );
    },
  );

  test('both markers are resolved in one pass, deletion first', () async {
    final prefs = await _prefs({
      'account_deletion_attempt_user': _deleted,
      'session_switch_from_user': 'user-prev',
    });
    final cleared = <String>[];
    await _port(cleared).resumePendingCleanup();
    expect(prefs.getString('account_deletion_attempt_user'), isNull);
    expect(prefs.getString('session_switch_from_user'), isNull);
    expect(cleared, ['clear', 'clear']);
  });

  test('a failing device cleanup is reported, but the other cleanup still runs '
      'and the failed marker stays for the next launch', () async {
    final prefs = await _prefs({
      'account_deletion_attempt_user': _deleted,
      'session_switch_from_user': 'user-prev',
    });
    final cleared = <String>[];
    await expectLater(
      _port(cleared, failClear: true).resumePendingCleanup(),
      throwsA(isA<StateError>()),
    );
    expect(
      prefs.getString('account_deletion_attempt_user'),
      isNull,
      reason: 'the deletion half does not depend on the device cleanup',
    );
    expect(prefs.getString('session_switch_from_user'), 'user-prev');
  });
}
