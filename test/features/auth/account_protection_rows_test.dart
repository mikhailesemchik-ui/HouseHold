import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/presentation/account_protection_rows.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_port.dart';

const _address = 'me@example.test';

Profile _profile({String state = 'active'}) => Profile(
  userId: 'user-a',
  publicId: 'HH-1',
  displayName: 'Mina',
  createdAt: DateTime(2026),
  accountState: state,
);

class _Host extends ConsumerWidget {
  const _Host(this.profile);

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: ListView(children: accountProtectionRows(context, ref, profile)),
  );
}

class _Rig {
  final events = <String>[];
  bool failPush = false;
  late FakeAuthPort port;
  late SessionSwitchCoordinator coordinator;
}

Future<_Rig> _pump(
  WidgetTester tester, {
  required AccountProtection? protection,
  Profile? profile,
  bool linked = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final rig = _Rig();
  rig.port = FakeAuthPort(
    userId: 'user-a',
    anonymous: !linked,
    email: linked ? _address : null,
  );
  rig.coordinator = SessionSwitchCoordinator(
    repository: EmailAccountRepository(rig.port),
    marker: SessionSwitchMarker(prefs),
    unregisterPushToken: () async {
      rig.events.add('unregisterPush');
      if (rig.failPush) throw StateError('offline');
    },
    restorePushRegistration: () async => rig.events.add('restorePush'),
    clearDeviceData: () async => rig.events.add('clearDeviceData'),
    onIdentityChanged: () => rig.events.add('identityChanged'),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountProtectionProvider.overrideWith((ref) async => protection),
        sessionSwitchCoordinatorProvider.overrideWith(
          (ref) async => rig.coordinator,
        ),
      ],
      child: MaterialApp(home: _Host(profile ?? _profile())),
    ),
  );
  await tester.pumpAndSettle();
  return rig;
}

void main() {
  testWidgets('an anonymous account is offered protection and no sign out', (
    tester,
  ) async {
    await _pump(
      tester,
      protection: const AccountUnprotected('user-a'),
      linked: false,
    );
    expect(find.text('Protect your account'), findsOneWidget);
    expect(find.textContaining('Link an email to recover'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Account protected'), findsNothing);
  });

  testWidgets('a pending email is shown as unverified, not as protected', (
    tester,
  ) async {
    await _pump(
      tester,
      protection: const AccountVerificationPending('user-a', _address),
      linked: false,
    );
    expect(find.text('Finish verifying your email'), findsOneWidget);
    expect(find.textContaining('not verified yet'), findsOneWidget);
    expect(find.text('Account protected'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('a verified account shows its email, sign out, no link action', (
    tester,
  ) async {
    await _pump(tester, protection: const AccountProtected('user-a', _address));
    expect(find.text('Account protected'), findsOneWidget);
    expect(find.text(_address), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Protect your account'), findsNothing);
  });

  testWidgets('a deleting account is offered no email actions', (tester) async {
    await _pump(
      tester,
      protection: const AccountProtected('user-a', _address),
      profile: _profile(state: 'deleting'),
    );
    expect(find.text('Account protected'), findsNothing);
    expect(find.text('Protect your account'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('sign out needs confirmation; cancelling changes nothing', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      protection: const AccountProtected('user-a', _address),
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rig.events, isEmpty);
    expect(rig.port.userId, 'user-a');
  });

  testWidgets('a confirmed sign out goes through the coordinator in order', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      protection: const AccountProtected('user-a', _address),
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(rig.events, [
      'unregisterPush',
      'identityChanged',
      'clearDeviceData',
    ]);
    expect(rig.port.userId, isNull);
    expect(
      rig.port.calls.where((c) => c.contains('Anonym')),
      isEmpty,
      reason: 'no guest is created after sign out',
    );
  });

  testWidgets('a failed push cleanup keeps the session and says so', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      protection: const AccountProtected('user-a', _address),
    );
    rig.failPush = true;
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(rig.port.userId, 'user-a');
    expect(rig.port.calls, isNot(contains('signOutLocal')));
    expect(find.textContaining("Couldn't finish switching"), findsOneWidget);
  });

  testWidgets(
    'the coordinator itself refuses to sign out an unlinked account',
    (tester) async {
      final rig = await _pump(
        tester,
        protection: const AccountUnprotected('user-a'),
        linked: false,
      );
      await expectLater(rig.coordinator.signOut(), throwsA(anything));
      expect(rig.port.userId, 'user-a');
      expect(rig.events, isEmpty);
    },
  );
}
