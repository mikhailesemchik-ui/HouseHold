// ignore_for_file: invalid_use_of_visible_for_testing_member
// Real supabase_flutter persistence check against the ISOLATED local stack
// (see f1_sdk_verification_test.dart for the required environment). Kept in its
// own file because TestWidgetsFlutterBinding blocks HTTP unless overridden.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _enabled =
    _env['HH_ALLOW_STACK'] == 'hhsqltest' &&
    (_env['HH_AUTH_URL'] ?? '') == 'http://127.0.0.1:55421' &&
    _env['HH_ANON_KEY'] != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!_enabled) {
    test('skipped: isolated local stack not configured', () {}, skip: true);
    return;
  }
  setUpAll(() => HttpOverrides.global = null);

  test(
    'supabase_flutter persists the session and restores the same user',
    () async {
      SharedPreferences.setMockInitialValues({});
      Future<void> init() => Supabase.initialize(
        url: _env['HH_AUTH_URL']!,
        publishableKey: _env['HH_ANON_KEY']!,
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      );
      await init();
      final first = await Supabase.instance.client.auth.signInAnonymously();
      final id = first.user!.id;
      final file = _env['HH_IDS_FILE'];
      if (file != null) {
        File(file).writeAsStringSync('$id\n', mode: FileMode.append);
      }
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs
          .getKeys()
          .where((k) => k.contains('auth-token'))
          .toList();
      // ignore: avoid_print
      print('persisted session keys: $persisted');
      expect(persisted, isNotEmpty);
      await Supabase.instance.dispose();

      await init();
      expect(
        Supabase.instance.client.auth.currentUser?.id,
        id,
        reason:
            'a restart restores the persisted session, no new anonymous user',
      );
      final refreshed = await Supabase.instance.client.auth.refreshSession();
      expect(refreshed.user!.id, id);
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
      expect(prefs.getKeys().where((k) => k.contains('auth-token')), isEmpty);
      await Supabase.instance.dispose();
    },
  );
}
