import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/profile/presentation/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAccountRepository implements AccountRepository {
  _FakeAccountRepository({this.blockers = const [], this.failure, this.gate});

  final List<OwnedHousehold> blockers;
  final AccountDeletionFailure? failure;
  final Completer<void>? gate;
  int deleteCalls = 0;
  int signOutCalls = 0;

  @override
  Future<List<OwnedHousehold>> fetchBlockers() async => blockers;

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    if (gate != null) await gate!.future;
    if (failure != null) throw AccountDeletionException(failure!);
  }

  @override
  Future<void> endLocalSession() async => signOutCalls++;

  @override
  Future<bool?> isAccountGone(String userId) async => null;
}

class _FakeHomes extends HomesNotifier {
  @override
  Future<List<Household>> build() async => [];
}

Profile _profile({String state = 'active'}) => Profile(
  userId: 'user-1',
  publicId: 'alice#1',
  displayName: 'Alice',
  createdAt: DateTime.utc(2026, 8, 1),
  accountState: state,
);

Future<void> _pump(
  WidgetTester tester,
  _FakeAccountRepository repo, {
  String state = 'active',
}) async {
  SharedPreferences.setMockInitialValues({
    'pending_financial_op/expense/user-1/hh-1': '[{"id":"a","hash":"h"}]',
    'pending_financial_op/expense/user-2/hh-1': '[{"id":"b","hash":"h"}]',
  });
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/profile',
    routes: [
      GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
      GoRoute(path: '/homes', builder: (_, _) => const Text('HOMES SCREEN')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentProfileProvider.overrideWith(
          (ref) async => _profile(state: state),
        ),
        accountRepositoryProvider.overrideWithValue(repo),
        homesProvider.overrideWith(_FakeHomes.new),
      ],
      child: MaterialApp.router(theme: appTheme, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _confirmButton => find.byType(FilledButton);

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('Delete account'));
  await tester.pumpAndSettle();
}

bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_confirmButton).onPressed != null;

void main() {
  group('Delete account entry', () {
    testWidgets('is available on the profile screen', (tester) async {
      await _pump(tester, _FakeAccountRepository());
      expect(find.text('Delete account'), findsOneWidget);
      expect(find.text('Finish deleting account'), findsNothing);
    });

    testWidgets('offers to finish an interrupted deletion', (tester) async {
      await _pump(tester, _FakeAccountRepository(), state: 'deleting');
      expect(find.text('Finish deleting account'), findsOneWidget);
      expect(find.text('Delete account'), findsNothing);
    });
  });

  group('ownership prerequisites', () {
    testWidgets('owning a home blocks deletion and lists the homes', (
      tester,
    ) async {
      final repo = _FakeAccountRepository(
        blockers: const [
          OwnedHousehold(name: 'Flat', activeMemberCount: 3),
          OwnedHousehold(name: 'Cabin', activeMemberCount: 1),
        ],
      );
      await _pump(tester, repo);
      await _openDialog(tester);

      expect(find.text('Hand over your homes first'), findsOneWidget);
      expect(find.text('Flat (3 members)'), findsOneWidget);
      expect(find.text('Cabin (only you)'), findsOneWidget);
      expect(find.text('Type DELETE to confirm.'), findsNothing);
      expect(repo.deleteCalls, 0);
    });
  });

  group('confirmation', () {
    testWidgets('explains the consequences and starts disabled', (
      tester,
    ) async {
      await _pump(tester, _FakeAccountRepository());
      await _openDialog(tester);

      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(find.textContaining('Deleted member'), findsOneWidget);
      expect(find.textContaining('can no longer be settled'), findsOneWidget);
      expect(_enabled(tester), isFalse);
    });

    testWidgets('only the exact phrase enables the button', (tester) async {
      await _pump(tester, _FakeAccountRepository());
      await _openDialog(tester);

      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pump();
      expect(_enabled(tester), isFalse);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      expect(_enabled(tester), isTrue);
    });

    testWidgets('Cancel leaves the account alone', (tester) async {
      final repo = _FakeAccountRepository();
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, 0);
      expect(repo.signOutCalls, 0);
      expect(find.text('Delete account?'), findsNothing);
    });
  });

  group('deleting', () {
    testWidgets('success signs out locally and returns to the homes list', (
      tester,
    ) async {
      final repo = _FakeAccountRepository();
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, 1);
      expect(repo.signOutCalls, 1);
      expect(find.text('HOMES SCREEN'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains('user-1')), isEmpty);
      expect(
        prefs.getString('pending_financial_op/expense/user-2/hh-1'),
        isNotNull,
      );
      expect(prefs.getString('account_deletion_attempt_user'), isNull);
    });

    testWidgets('the attempt is recorded before the request is sent', (
      tester,
    ) async {
      final gate = Completer<void>();
      final repo = _FakeAccountRepository(gate: gate);
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('account_deletion_attempt_user'), 'user-1');
      expect(repo.deleteCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a second tap while deleting is ignored', (tester) async {
      final gate = Completer<void>();
      final repo = _FakeAccountRepository(gate: gate);
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_enabled(tester), isFalse);
      await tester.tap(_confirmButton, warnIfMissed: false);
      await tester.pump();
      expect(repo.deleteCalls, 1);
      expect(repo.signOutCalls, 0);

      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.signOutCalls, 1);
    });

    testWidgets('a retryable failure keeps the session and allows a retry', (
      tester,
    ) async {
      final repo = _FakeAccountRepository(
        failure: AccountDeletionFailure.retryable,
      );
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('did not finish'), findsOneWidget);
      expect(repo.signOutCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      // Kept: the next launch asks the server what really happened.
      expect(prefs.getString('account_deletion_attempt_user'), 'user-1');
      expect(
        prefs.getString('pending_financial_op/expense/user-1/hh-1'),
        isNotNull,
      );
      expect(_enabled(tester), isTrue);

      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();
      expect(repo.deleteCalls, 2);
    });

    testWidgets('a server-side ownership refusal is explained', (tester) async {
      final repo = _FakeAccountRepository(
        failure: AccountDeletionFailure.ownsHouseholds,
      );
      await _pump(tester, repo);
      await _openDialog(tester);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('still own a home'), findsOneWidget);
      expect(repo.signOutCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('account_deletion_attempt_user'), isNull);
      expect(
        prefs.getString('pending_financial_op/expense/user-1/hh-1'),
        isNotNull,
      );
    });

    testWidgets('resuming skips the ownership check and finishes', (
      tester,
    ) async {
      final repo = _FakeAccountRepository(
        blockers: const [OwnedHousehold(name: 'Stale', activeMemberCount: 2)],
      );
      await _pump(tester, repo, state: 'deleting');
      await tester.tap(find.text('Finish deleting account'));
      await tester.pumpAndSettle();

      expect(find.text('Finish deleting account?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();
      expect(repo.deleteCalls, 1);
      expect(find.text('HOMES SCREEN'), findsOneWidget);
    });
  });
}
