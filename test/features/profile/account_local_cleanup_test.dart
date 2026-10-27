import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAccountRepository implements AccountRepository {
  _FakeAccountRepository({this.gone});

  bool? gone;
  int signOutCalls = 0;
  final asked = <String>[];

  @override
  Future<bool?> isAccountGone(String userId) async {
    asked.add(userId);
    return gone;
  }

  @override
  Future<void> endLocalSession() async => signOutCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _deleted = 'user-deleted';
const _other = 'user-other';

Future<(SharedPreferences, AccountLocalCleanup, List<String>)> _setup({
  bool failWipe = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'pending_financial_op/expense/$_deleted/hh-1': '[{"id":"a","hash":"h1"}]',
    'pending_financial_op/settlement/$_deleted/hh-1':
        '[{"id":"b","hash":"h2"}]',
    'pending_financial_op/expense/$_deleted/hh-2': '[{"id":"c","hash":"h3"}]',
    'pending_financial_op/expense/$_other/hh-1': '[{"id":"d","hash":"h4"}]',
    'reminder_enabled': true,
    'widget_show_names': false,
  });
  final prefs = await SharedPreferences.getInstance();
  final wipes = <String>[];
  final cleanup = AccountLocalCleanup(
    prefs,
    clearDeviceData: () async {
      wipes.add('wipe');
      if (failWipe) throw StateError('platform not available');
    },
  );
  return (prefs, cleanup, wipes);
}

Set<String> _pendingKeys(SharedPreferences prefs) =>
    prefs.getKeys().where((k) => k.startsWith('pending_financial_op/')).toSet();

void main() {
  group('FinancialRequestStore.clearUser', () {
    test('removes every request id of that user and nothing else', () async {
      final (prefs, _, _) = await _setup();
      await FinancialRequestStore(prefs).clearUser(_deleted);

      expect(_pendingKeys(prefs), {
        'pending_financial_op/expense/$_other/hh-1',
      });
      expect(prefs.getBool('reminder_enabled'), isTrue);
      expect(prefs.getBool('widget_show_names'), isFalse);
    });

    test('is repeatable and leaves nothing sendable for the user', () async {
      final (prefs, _, _) = await _setup();
      final store = FinancialRequestStore(prefs);
      await store.clearUser(_deleted);
      await store.clearUser(_deleted);

      expect(
        store.pending(userId: _deleted, householdId: 'hh-1', kind: 'expense'),
        isEmpty,
      );
      expect(
        store.pending(userId: _other, householdId: 'hh-1', kind: 'expense'),
        hasLength(1),
      );
    });

    test('a user id that is a prefix of another is not matched', () async {
      SharedPreferences.setMockInitialValues({
        'pending_financial_op/expense/u1/hh': '[{"id":"a","hash":"h"}]',
        'pending_financial_op/expense/u10/hh': '[{"id":"b","hash":"h"}]',
      });
      final prefs = await SharedPreferences.getInstance();
      await FinancialRequestStore(prefs).clearUser('u1');

      expect(_pendingKeys(prefs), {'pending_financial_op/expense/u10/hh'});
    });
  });

  group('AccountLocalCleanup.finish', () {
    test(
      'clears ids, wipes device data, ends the session, then unmarks',
      () async {
        final (prefs, cleanup, wipes) = await _setup();
        final repo = _FakeAccountRepository();
        await cleanup.mark(_deleted);
        await cleanup.finish(_deleted, repo);

        expect(_pendingKeys(prefs), {
          'pending_financial_op/expense/$_other/hh-1',
        });
        expect(wipes, ['wipe']);
        expect(repo.signOutCalls, 1);
        expect(cleanup.markedUserId, isNull);
      },
    );

    test('a failing device wipe does not stop the rest', () async {
      final (prefs, cleanup, _) = await _setup(failWipe: true);
      final repo = _FakeAccountRepository();
      await cleanup.mark(_deleted);
      await cleanup.finish(_deleted, repo);

      expect(_pendingKeys(prefs), {
        'pending_financial_op/expense/$_other/hh-1',
      });
      expect(repo.signOutCalls, 1);
      expect(cleanup.markedUserId, isNull);
    });
  });

  group('AccountLocalCleanup.resumeIfPending', () {
    test('does nothing without a marker', () async {
      final (prefs, cleanup, wipes) = await _setup();
      final repo = _FakeAccountRepository(gone: true);
      await cleanup.resumeIfPending(repo);

      expect(repo.asked, isEmpty);
      expect(_pendingKeys(prefs), hasLength(4));
      expect(wipes, isEmpty);
    });

    test('finishes an interrupted cleanup once the account is gone', () async {
      final (prefs, cleanup, wipes) = await _setup();
      final repo = _FakeAccountRepository(gone: true);
      await cleanup.mark(_deleted); // app was killed right after the server

      await cleanup.resumeIfPending(repo);
      expect(_pendingKeys(prefs), {
        'pending_financial_op/expense/$_other/hh-1',
      });
      expect(wipes, ['wipe']);
      expect(repo.signOutCalls, 1);
      expect(cleanup.markedUserId, isNull);

      await cleanup.resumeIfPending(repo); // next launch: nothing left to do
      expect(repo.asked, [_deleted]);
    });

    test('keeps everything when the deletion never happened', () async {
      final (prefs, cleanup, wipes) = await _setup();
      final repo = _FakeAccountRepository(gone: false);
      await cleanup.mark(_deleted);
      await cleanup.resumeIfPending(repo);

      expect(_pendingKeys(prefs), hasLength(4));
      expect(wipes, isEmpty);
      expect(repo.signOutCalls, 0);
      expect(cleanup.markedUserId, isNull);
    });

    test('an unknown answer changes nothing and is retried later', () async {
      final (prefs, cleanup, wipes) = await _setup();
      final repo = _FakeAccountRepository(gone: null);
      await cleanup.mark(_deleted);
      await cleanup.resumeIfPending(repo);

      expect(_pendingKeys(prefs), hasLength(4));
      expect(wipes, isEmpty);
      expect(repo.signOutCalls, 0);
      expect(cleanup.markedUserId, _deleted);

      repo.gone = true;
      await cleanup.resumeIfPending(repo);
      expect(cleanup.markedUserId, isNull);
      expect(repo.signOutCalls, 1);
    });
  });
}
