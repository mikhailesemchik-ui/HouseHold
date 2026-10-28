import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/profile/presentation/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plays the server of an email-linked account: the first request without a
/// code is refused with `verificationRequired`; then [results] decide.
class _LinkedRepository implements AccountRepository {
  _LinkedRepository({List<AccountDeletionFailure?>? results, this.gate})
    : results = results ?? [];

  /// Outcomes for requests that carry a code (null = success).
  final List<AccountDeletionFailure?> results;
  final Completer<void>? gate;
  final calls = <String?>[]; // the code each deleteAccount call carried
  int codesSent = 0;
  int signOutCalls = 0;
  String? userId = 'user-1';
  Object? sendError;
  bool deletionStarted = false;

  @override
  String? get currentUserId => userId;

  @override
  Future<List<OwnedHousehold>> fetchBlockers() async => const [];

  @override
  Future<void> sendDeletionCode() async {
    codesSent++;
    if (sendError != null) throw sendError!;
  }

  @override
  Future<void> deleteAccount({String? code}) async {
    calls.add(code);
    if (gate != null) await gate!.future;
    if (code == null && !deletionStarted) {
      throw const AccountDeletionException(
        AccountDeletionFailure.verificationRequired,
      );
    }
    final next = results.isEmpty ? null : results.removeAt(0);
    if (next != null) {
      if (next == AccountDeletionFailure.retryable) deletionStarted = true;
      throw AccountDeletionException(next);
    }
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

Future<void> _pump(WidgetTester tester, _LinkedRepository repo) async {
  SharedPreferences.setMockInitialValues({});
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
          (ref) async => Profile(
            userId: 'user-1',
            publicId: 'alice#1',
            displayName: 'Alice',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
        ),
        accountRepositoryProvider.overrideWithValue(repo),
        homesProvider.overrideWith(_FakeHomes.new),
      ],
      child: MaterialApp.router(theme: appTheme, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _primary => find.byType(FilledButton);
bool _enabled(WidgetTester t) =>
    t.widget<FilledButton>(_primary).onPressed != null;

/// Opens the dialog, types the phrase and presses Delete: for a linked
/// account this ends on the code step.
Future<void> _toCodeStep(WidgetTester tester) async {
  await tester.tap(find.text('Delete account'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'DELETE');
  await tester.pump();
  await tester.tap(_primary);
  await tester.pumpAndSettle();
}

Future<void> _submitCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byType(TextField), code);
  await tester.pump();
  await tester.tap(_primary);
  await tester.pumpAndSettle();
}

void main() {
  group('failure mapping', () {
    test('only the machine-readable error key is used', () {
      AccountDeletionFailure f(int s, [Object? d]) =>
          accountDeletionFailureFor(s, d);
      expect(
        f(409, {'error': 'owns_households'}),
        AccountDeletionFailure.ownsHouseholds,
      );
      expect(
        f(403, {'error': 'reverification_required'}),
        AccountDeletionFailure.verificationRequired,
      );
      expect(
        f(403, {'error': 'verification_failed'}),
        AccountDeletionFailure.codeRejected,
      );
      expect(
        f(403, {'error': 'reverification_unavailable'}),
        AccountDeletionFailure.verificationUnavailable,
      );
      expect(
        f(429, {'error': 'rate_limited'}),
        AccountDeletionFailure.rateLimited,
      );
      expect(
        f(502, {'error': 'verification_unavailable'}),
        AccountDeletionFailure.verificationUnavailable,
      );
      expect(
        f(502, {'error': 'auth_delete_failed'}),
        AccountDeletionFailure.retryable,
      );
      expect(
        f(502, {'error': 'finalize_failed'}),
        AccountDeletionFailure.retryable,
      );
      expect(f(500, 'text body'), AccountDeletionFailure.retryable);
      expect(f(0), AccountDeletionFailure.retryable);
    });

    test('only a retryable failure keeps the local deletion marker', () {
      for (final failure in AccountDeletionFailure.values) {
        expect(
          failure.leavesAccountUntouched,
          failure != AccountDeletionFailure.retryable,
        );
      }
    });
  });

  group('linked account: emailed code', () {
    testWidgets('nothing is mailed or sent when the dialog opens', (
      tester,
    ) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(repo.codesSent, 0);
    });

    testWidgets('the server asks for a code; one is mailed, deletion waits', (
      tester,
    ) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await _toCodeStep(tester);
      expect(find.text('6-digit code'), findsOneWidget);
      expect(find.textContaining('confirms this is your account'), findsOne);
      expect(repo.codesSent, 1);
      expect(repo.calls, [null], reason: 'one refused request, no code');
      expect(repo.signOutCalls, 0);
      expect(_enabled(tester), isFalse, reason: 'needs 6 digits');
    });

    testWidgets('a correct code deletes, ends the session, leaves Profile', (
      tester,
    ) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await _submitCode(tester, '123456');
      expect(repo.calls, [null, '123456']);
      expect(repo.signOutCalls, 1);
      expect(find.text('HOMES SCREEN'), findsOneWidget);
    });

    testWidgets('the code is not kept after it was sent or stored', (
      tester,
    ) async {
      final repo = _LinkedRepository(
        results: [AccountDeletionFailure.codeRejected],
      );
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await _submitCode(tester, '654321');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join(),
        isNot(contains('654321')),
      );
    });

    testWidgets('a wrong code is refused, keeps the session, can be retried', (
      tester,
    ) async {
      final repo = _LinkedRepository(
        results: [AccountDeletionFailure.codeRejected, null],
      );
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await _submitCode(tester, '111111');
      expect(find.textContaining("didn't work"), findsOneWidget);
      expect(repo.signOutCalls, 0);
      expect(find.text('HOMES SCREEN'), findsNothing);
      await _submitCode(tester, '222222');
      expect(repo.calls, [null, '111111', '222222']);
      expect(find.text('HOMES SCREEN'), findsOneWidget);
    });

    testWidgets('rate limiting and unavailable verification are explained', (
      tester,
    ) async {
      final repo = _LinkedRepository(
        results: [
          AccountDeletionFailure.rateLimited,
          AccountDeletionFailure.verificationUnavailable,
        ],
      );
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await _submitCode(tester, '111111');
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      await _submitCode(tester, '111111');
      expect(find.textContaining("couldn't check the code"), findsOneWidget);
      expect(repo.signOutCalls, 0);
    });

    testWidgets('a failed email send is explained and can be repeated', (
      tester,
    ) async {
      final repo = _LinkedRepository()
        ..sendError = const EmailAuthException(EmailAuthFailure.rateLimited);
      await _pump(tester, repo);
      await _toCodeStep(tester);
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      repo.sendError = null;
      await tester.tap(find.text('Send a new code'));
      await tester.pumpAndSettle();
      expect(repo.codesSent, 2);
      expect(find.textContaining('Too many attempts'), findsNothing);
    });

    testWidgets('resend has a cooldown', (tester) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await _toCodeStep(tester);
      expect(find.textContaining('Send a new code in'), findsOneWidget);
      await tester.tap(find.textContaining('Send a new code in'));
      await tester.pump();
      expect(repo.codesSent, 1);
    });

    testWidgets('a double tap sends one request', (tester) async {
      final gate = Completer<void>();
      final repo = _LinkedRepository(gate: gate);
      await _pump(tester, repo);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(_primary);
      await tester.tap(_primary, warnIfMissed: false);
      await tester.pump();
      expect(repo.calls, hasLength(1));
      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('after the server started, a retry needs no new code', (
      tester,
    ) async {
      final repo = _LinkedRepository(
        results: [AccountDeletionFailure.retryable, null],
      );
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await _submitCode(tester, '123456');
      expect(find.text('Try again'), findsOneWidget);
      expect(repo.signOutCalls, 0);
      await tester.tap(_primary);
      await tester.pumpAndSettle();
      expect(repo.calls, [null, '123456', null]);
      expect(repo.codesSent, 1, reason: 'no extra mail for a resumed deletion');
      expect(find.text('HOMES SCREEN'), findsOneWidget);
    });

    testWidgets('an account change stops the flow before anything is sent', (
      tester,
    ) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      repo.userId = 'someone-else';
      await tester.tap(_primary);
      await tester.pumpAndSettle();
      expect(find.textContaining('account changed'), findsOneWidget);
      expect(repo.calls, isEmpty);
      expect(repo.codesSent, 0);
      expect(repo.signOutCalls, 0);
    });

    testWidgets('cancelling on the code step changes nothing further', (
      tester,
    ) async {
      final repo = _LinkedRepository();
      await _pump(tester, repo);
      await _toCodeStep(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.calls, [null]);
      expect(repo.signOutCalls, 0);
      expect(find.text('Delete account?'), findsNothing);
    });
  });
}
