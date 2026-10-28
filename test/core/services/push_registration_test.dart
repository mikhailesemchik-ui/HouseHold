import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/push_registration_sync.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _a = 'user-a';
const _b = 'user-b';

class _Tokens implements PushTokenProvider {
  _Tokens(this.token);

  String? token;

  @override
  String? get platform => 'android';

  @override
  Future<String?> getToken() async => token;
}

/// A fake server with the real ownership rule: one owner per token. Rows are
/// 'owner|token'. Registering moves the token to the signed-in user; releasing
/// removes it from everyone else without registering it for the caller.
class _Rig {
  _Rig({String? signedInAs = _a, String token = 'tok-1', this.deletionOf})
    : signedIn = signedInAs,
      tokens = _Tokens(token) {
    sync = PushRegistrationSync(
      currentUserId: () => signedIn,
      tokenProvider: tokens,
      registerToken: (token, platform) async {
        if (failRegister) throw StateError('offline');
        rows.removeWhere((r) => r.endsWith('|$token'));
        rows.add('$signedIn|$token');
      },
      unregisterToken: (token) async {
        if (failUnregister) throw StateError('offline');
        rows.remove('$signedIn|$token'); // row level security: own rows only
      },
      releaseForeignRegistrations: (token, platform) async {
        if (failRelease) throw StateError('offline');
        releases++;
        rows.removeWhere(
          (r) => r.endsWith('|$token') && !r.startsWith('$signedIn|'),
        );
      },
      isDeletionPending: (id) async => id == deletionOf,
    );
  }

  String? signedIn;
  final _Tokens tokens;
  final String? deletionOf;
  final rows = <String>{};
  int releases = 0;
  bool failRegister = false;
  bool failUnregister = false;
  bool failRelease = false;
  late final PushRegistrationSync sync;
}

Future<void> _optIn(String user) async {
  final s = HouseholdUpdatesPushSettings.forUser(user);
  await s.setEnabled(true);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('opt-in and token are stored per user', () {
    test('one user\'s settings are invisible to another', () async {
      final a = HouseholdUpdatesPushSettings.forUser(_a);
      final b = HouseholdUpdatesPushSettings.forUser(_b);
      await a.setEnabled(true);
      await a.setLastRegisteredToken('tok-a');
      expect(await b.isEnabled(), isFalse);
      expect(await b.lastRegisteredToken(), isNull);
      expect(await a.isEnabled(), isTrue);
      expect(await a.lastRegisteredToken(), 'tok-a');
    });

    test('an empty user id is refused', () {
      expect(
        () => HouseholdUpdatesPushSettings.forUser(''),
        throwsArgumentError,
      );
    });

    test('a device-wide opt-in saved before accounts could change goes to the '
        'first user only, and is removed', () async {
      SharedPreferences.setMockInitialValues({
        'household_updates_push_enabled': true,
        'household_updates_push_token': 'tok-old',
      });
      await HouseholdUpdatesPushSettings.adoptLegacyFor(_a);
      await HouseholdUpdatesPushSettings.adoptLegacyFor(_b);
      final a = HouseholdUpdatesPushSettings.forUser(_a);
      final b = HouseholdUpdatesPushSettings.forUser(_b);
      expect(await a.isEnabled(), isTrue);
      expect(await a.lastRegisteredToken(), 'tok-old');
      expect(await b.isEnabled(), isFalse, reason: 'cannot be claimed twice');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('household_updates_push_enabled'), isFalse);
    });

    test('adopting never overwrites a user\'s own newer settings', () async {
      SharedPreferences.setMockInitialValues({
        'household_updates_push_enabled': true,
        'household_updates_push_enabled/$_a': false,
      });
      await HouseholdUpdatesPushSettings.adoptLegacyFor(_a);
      expect(
        await HouseholdUpdatesPushSettings.forUser(_a).isEnabled(),
        isFalse,
      );
    });
  });

  group('registering the device for the signed-in user', () {
    test('an opted-in user is registered, once, idempotently', () async {
      final rig = _Rig();
      await _optIn(_a);
      await rig.sync.ensureRegistered(_a);
      await rig.sync.ensureRegistered(_a);
      expect(rig.rows, {'$_a|tok-1'});
      expect(rig.releases, 0);
      expect(
        await HouseholdUpdatesPushSettings.forUser(_a).lastRegisteredToken(),
        'tok-1',
      );
    });

    test(
      'a user who did not opt in registers nothing but RELEASES the previous '
      'owner (a stale registration of an account that lost its session)',
      () async {
        final rig = _Rig(signedInAs: _b);
        rig.rows.add('$_a|tok-1'); // left behind when A\'s session was revoked
        await _optIn(_a);
        await rig.sync.ensureRegistered(_b);
        expect(rig.rows, isEmpty, reason: 'A\'s private notifications stop');
        expect(rig.releases, 1);
        expect(
          await HouseholdUpdatesPushSettings.forUser(_b).lastRegisteredToken(),
          isNull,
        );
      },
    );

    test(
      'an opted-in new user takes the token over from the stale owner',
      () async {
        final rig = _Rig(signedInAs: _b);
        rig.rows.add('$_a|tok-1');
        await _optIn(_b);
        await rig.sync.ensureRegistered(_b);
        expect(rig.rows, {'$_b|tok-1'});
      },
    );

    test(
      'the new user opts in later; the previous owner never comes back',
      () async {
        final rig = _Rig();
        await _optIn(_a);
        await rig.sync.ensureRegistered(_a);
        // approved switch: A\'s registration is removed under A\'s session
        rig.rows.remove('$_a|tok-1');
        await HouseholdUpdatesPushSettings.forUser(
          _a,
        ).setLastRegisteredToken(null);
        rig.signedIn = _b;
        await rig.sync.ensureRegistered(_b);
        expect(rig.rows, isEmpty);
        await _optIn(_b);
        await rig.sync.ensureRegistered(_b);
        expect(rig.rows, {'$_b|tok-1'});
      },
    );

    test(
      'A returning later is registered again from A\'s own opt-in',
      () async {
        final rig = _Rig(signedInAs: _b);
        await _optIn(_a);
        rig.signedIn = _a;
        await rig.sync.ensureRegistered(_a);
        expect(rig.rows, {'$_a|tok-1'});
      },
    );

    test('a token rotation moves the user\'s own registration only', () async {
      final rig = _Rig();
      await _optIn(_a);
      await rig.sync.ensureRegistered(_a);
      rig.rows.add('$_b|someone-elses'); // another user\'s device
      rig.tokens.token = 'tok-2';
      await rig.sync.ensureRegistered(_a);
      expect(rig.rows, {'$_a|tok-2', '$_b|someone-elses'});
    });

    test(
      'nothing is registered or released if the session changed meanwhile',
      () async {
        final rig = _Rig(signedInAs: _b);
        await _optIn(_a);
        rig.rows.add('$_a|tok-1');
        await rig.sync.ensureRegistered(_a); // caller asked for A, session is B
        expect(rig.rows, {'$_a|tok-1'});
        expect(rig.releases, 0);
      },
    );

    test(
      'an unresolved account deletion blocks registration and release',
      () async {
        final rig = _Rig(deletionOf: _a);
        await _optIn(_a);
        await rig.sync.ensureRegistered(_a);
        expect(rig.rows, isEmpty);
        expect(rig.releases, 0);
      },
    );

    test(
      'no token available (permission off) registers and releases nothing',
      () async {
        final rig = _Rig();
        rig.tokens.token = null;
        await _optIn(_a);
        await rig.sync.ensureRegistered(_a);
        expect(rig.rows, isEmpty);
        expect(rig.releases, 0);
      },
    );

    test(
      'a failed registration is thrown, never reported as success',
      () async {
        final rig = _Rig()..failRegister = true;
        await _optIn(_a);
        await expectLater(rig.sync.ensureRegistered(_a), throwsStateError);
        expect(
          await HouseholdUpdatesPushSettings.forUser(_a).lastRegisteredToken(),
          isNull,
          reason: 'the token is only remembered after the server accepted it',
        );
      },
    );

    test('a failed release is thrown too', () async {
      final rig = _Rig(signedInAs: _b)..failRelease = true;
      rig.rows.add('$_a|tok-1');
      await expectLater(rig.sync.ensureRegistered(_b), throwsStateError);
      expect(rig.rows, {'$_a|tok-1'}, reason: 'nothing was claimed to be done');
    });
  });
}
