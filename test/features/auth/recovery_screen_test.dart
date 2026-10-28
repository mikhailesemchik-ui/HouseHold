import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';
import 'package:household_os/features/auth/presentation/recovery_screen.dart';

class _Actions implements RecoveryActions {
  final calls = <String>[];
  Object? requestError;
  Object? verifyError;

  @override
  Future<void> requestCode(String email) async {
    calls.add('request');
    if (requestError != null) throw requestError!;
  }

  @override
  Future<AuthIdentity> verify(String email, String code) async {
    calls.add('verify');
    if (verifyError != null) throw verifyError!;
    return const AuthIdentity(
      userId: 'u',
      isAnonymous: false,
      email: 'me@example.test',
      isEmailConfirmed: true,
    );
  }
}

class _Rig {
  final actions = _Actions();
  DateTime now = DateTime(2026, 1, 1, 12);

  Widget get app => ProviderScope(
    overrides: [
      recoveryActionsProvider.overrideWithValue(actions),
      recoveryClockProvider.overrideWithValue(() => now),
    ],
    child: MaterialApp(theme: appTheme, home: const RecoveryScreen()),
  );
}

Future<void> _toCodeStep(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(rig.app);
  await tester.enterText(find.byType(TextField), 'me@example.test');
  await tester.tap(find.text('Send code'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('step one asks for an email and offers no guest account', (
    tester,
  ) async {
    await tester.pumpWidget(_Rig().app);
    expect(find.text('Send code'), findsOneWidget);
    expect(find.text('I already have a code'), findsOneWidget);
    expect(find.text('Get started'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('requesting a code shows neutral wording that does not claim '
      'delivery or reveal whether the account exists', (tester) async {
    final rig = _Rig();
    await _toCodeStep(tester, rig);
    expect(rig.actions.calls, ['request']);
    expect(
      find.textContaining('If me@example.test belongs to an account'),
      findsOneWidget,
    );
    expect(find.textContaining('We sent'), findsNothing);
    expect(find.textContaining('not found'), findsNothing);
  });

  testWidgets('an invalid address shows a calm message and stays on step one', (
    tester,
  ) async {
    final rig = _Rig()
      ..actions.requestError = const EmailAuthException(
        EmailAuthFailure.invalidEmail,
      );
    await tester.pumpWidget(rig.app);
    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.text('Send code'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);
  });

  testWidgets('the code field takes only digits, at most six (paste safe)', (
    tester,
  ) async {
    await _toCodeStep(tester, _Rig());
    await tester.enterText(find.byType(TextField), '12 34-5678');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '123456',
    );
  });

  testWidgets('Sign in is disabled until six digits are entered', (
    tester,
  ) async {
    await _toCodeStep(tester, _Rig());
    FilledButton button() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(button().onPressed, isNotNull);
  });

  testWidgets('a wrong or expired code shows a safe message, clears the field '
      'and allows another try', (tester) async {
    final rig = _Rig();
    await _toCodeStep(tester, rig);
    rig.actions.verifyError = const EmailAuthException(
      EmailAuthFailure.codeRejected,
    );
    await tester.enterText(find.byType(TextField), '000000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining("That code didn't work"), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('otp_'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
      reason: 'the rejected code is not kept',
    );
  });

  testWidgets('a network failure while signing in is explained plainly', (
    tester,
  ) async {
    final rig = _Rig();
    await _toCodeStep(tester, rig);
    rig.actions.verifyError = const EmailAuthException(
      EmailAuthFailure.network,
    );
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining("Couldn't connect"), findsOneWidget);
  });

  testWidgets('resend is locked with a countdown, then available', (
    tester,
  ) async {
    final rig = _Rig();
    await _toCodeStep(tester, rig);
    expect(find.textContaining('Send a new code in'), findsOneWidget);
    TextButton resend() => tester.widget<TextButton>(
      find.ancestor(
        of: find.textContaining('Send a new code'),
        matching: find.byType(TextButton),
      ),
    );
    expect(resend().onPressed, isNull);

    rig.now = rig.now.add(const Duration(seconds: 61)); // e.g. after background
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Send a new code'), findsOneWidget);
    expect(resend().onPressed, isNotNull);
    await tester.tap(find.text('Send a new code'));
    await tester.pump();
    await tester.pump();
    expect(rig.actions.calls.where((c) => c == 'request'), hasLength(2));
    expect(find.textContaining('Send a new code in'), findsOneWidget);
  });

  testWidgets('"Use a different email" returns to step one with the address', (
    tester,
  ) async {
    await _toCodeStep(tester, _Rig());
    await tester.tap(find.text('Use a different email'));
    await tester.pump();
    expect(find.text('Send code'), findsOneWidget);
    expect(find.text('me@example.test'), findsOneWidget);
  });

  testWidgets('both steps fit a small screen with large text and a keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = _Rig();
    Widget wrap() => MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 480),
        textScaler: TextScaler.linear(1.6),
        viewInsets: EdgeInsets.only(bottom: 200),
      ),
      child: rig.app,
    );
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'me@example.test');
    await tester.tap(find.text('Send code'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('6-digit'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('recoveryMessage', () {
    test('never exposes technical detail for any failure', () {
      for (final f in EmailAuthFailure.values) {
        final m = recoveryMessage(f);
        expect(m, isNotEmpty);
        expect(m.toLowerCase(), isNot(contains('http')));
        expect(m.toLowerCase(), isNot(contains('token')));
        expect(m.toLowerCase(), isNot(contains('otp')));
        expect(m, isNot(contains('422')));
      }
    });
  });
}
