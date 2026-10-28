import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';

/// Calm, non-technical wording for each failure. None of it names an HTTP
/// status, server message or token.
String recoveryMessage(EmailAuthFailure failure) => switch (failure) {
  EmailAuthFailure.invalidEmail => 'Enter a valid email address.',
  EmailAuthFailure.network =>
    "Couldn't connect. Check your internet connection and try again.",
  EmailAuthFailure.rateLimited =>
    'Too many attempts. Please wait a moment and try again.',
  EmailAuthFailure.codeRejected =>
    "That code didn't work. Check it, or request a new one.",
  EmailAuthFailure.accountNotActive =>
    "This account is being deleted and can't be opened.",
  EmailAuthFailure.anonymousAccountAtRisk =>
    "You're already signed in on this device.",
  EmailAuthFailure.pushCleanupFailed =>
    "Couldn't finish switching accounts on this device. Check your "
        'connection and try again.',
  _ => 'Something went wrong. Try again.',
};

/// Sign in to an existing account with an emailed code. It never creates an
/// account and never signs in anonymously.
class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-evaluates the resend countdown; the cooldown itself is a timestamp,
    // so it stays correct across backgrounding.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recoveryFlowProvider);
    return Scaffold(
      backgroundColor: appFlatBackgroundFallback,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.base,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AppScreenHeader(
                    leading: Center(child: AppBackButton()),
                    title: 'Sign in',
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  switch (state) {
                    RecoveryEmailEntry() ||
                    RecoveryRequestingCode() => _emailStep(state),
                    RecoveryCodeEntry() ||
                    RecoveryVerifying() => _codeStep(state),
                    RecoverySucceeded() => const _SigningIn(),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emailStep(RecoveryState state) {
    final requesting = state is RecoveryRequestingCode;
    final failure = state is RecoveryEmailEntry ? state.failure : null;
    final notifier = ref.read(recoveryFlowProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Use the email you added to your account. We will send you a '
          '6-digit code.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _email,
          enabled: !requesting,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Email'),
          onSubmitted: requesting ? null : (v) => notifier.requestCode(v),
        ),
        if (failure != null) _ErrorText(recoveryMessage(failure)),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: requesting
              ? null
              : () => notifier.requestCode(_email.text),
          child: requesting ? const _ButtonSpinner() : const Text('Send code'),
        ),
        TextButton(
          onPressed: requesting ? null : () => notifier.haveCode(_email.text),
          child: const Text('I already have a code'),
        ),
      ],
    );
  }

  Widget _codeStep(RecoveryState state) {
    final notifier = ref.read(recoveryFlowProvider.notifier);
    final email = state is RecoveryCodeEntry
        ? state.email
        : (state as RecoveryVerifying).email;
    final entry = state is RecoveryCodeEntry ? state : null;
    final verifying = state is RecoveryVerifying;
    final busy = verifying || (entry?.isResending ?? false);
    final remaining = entry == null
        ? Duration.zero
        : entry.resendAvailableAt.difference(ref.read(recoveryClockProvider)());
    final canResend = entry != null && notifier.canResend(entry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'If $email belongs to an account, a 6-digit code is on its way. '
          'Enter it below.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _code,
          enabled: !busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.oneTimeCode],
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(labelText: '6-digit code'),
          onChanged: (_) => setState(() {}),
          onSubmitted: busy ? null : (v) => _submit(notifier),
        ),
        if (entry?.failure != null)
          _ErrorText(recoveryMessage(entry!.failure!)),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: busy || _code.text.length != 6
              ? null
              : () => _submit(notifier),
          child: verifying ? const _ButtonSpinner() : const Text('Sign in'),
        ),
        TextButton(
          onPressed: canResend ? notifier.resend : null,
          child: Text(
            canResend || entry == null || entry.isResending
                ? 'Send a new code'
                : 'Send a new code in ${remaining.inSeconds + 1}s',
          ),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () {
                  _code.clear();
                  _email.text = email;
                  notifier.editEmail();
                },
          child: const Text('Use a different email'),
        ),
      ],
    );
  }

  Future<void> _submit(RecoveryFlowNotifier notifier) async {
    final code = _code.text;
    // The code lives only in the field and this call; it is cleared at once.
    _code.clear();
    await notifier.verify(code);
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5),
  );
}

class _SigningIn extends StatelessWidget {
  const _SigningIn();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: AppSpacing.xxl),
    child: Center(child: CircularProgressIndicator()),
  );
}
