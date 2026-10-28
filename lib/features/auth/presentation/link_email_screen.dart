import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/link_email_flow.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';
import 'package:household_os/features/auth/presentation/recovery_screen.dart';

String linkEmailMessage(EmailAuthFailure failure) => switch (failure) {
  EmailAuthFailure.emailInUse =>
    'That email is already used by another account. Use a different one.',
  EmailAuthFailure.alreadyLinked => 'This account already has an email.',
  EmailAuthFailure.sessionChanged =>
    'Your account changed. Close this screen and start again.',
  EmailAuthFailure.notSignedIn =>
    'You are signed out. Close this screen and start again.',
  EmailAuthFailure.identityMismatch =>
    "We couldn't confirm your email. Request a new code and try again.",
  EmailAuthFailure.accountNotActive =>
    "This account is being deleted and can't be protected.",
  _ => recoveryMessage(failure),
};

/// Links an email to the CURRENT account in two steps: address, then the
/// 6-digit code. It never signs in as anyone else and never leaves this
/// account; the home and everything in it stay as they are.
class LinkEmailScreen extends ConsumerStatefulWidget {
  const LinkEmailScreen({super.key, this.pending});

  /// A verification that is already waiting on the server.
  final AccountVerificationPending? pending;

  @override
  ConsumerState<LinkEmailScreen> createState() => _LinkEmailScreenState();
}

class _LinkEmailScreenState extends ConsumerState<LinkEmailScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    final pending = widget.pending;
    if (pending != null) {
      // Provider state may not change during initState.
      Future.microtask(
        () => ref.read(linkEmailFlowProvider.notifier).resumePending(pending),
      );
    }
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
    final state = ref.watch(linkEmailFlowProvider);
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
                    title: 'Protect account',
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  switch (state) {
                    LinkEmailEntry() ||
                    LinkEmailRequesting() => _emailStep(state),
                    LinkEmailCodeEntry() ||
                    LinkEmailVerifying() => _codeStep(state),
                    LinkEmailDone() => _done(state),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emailStep(LinkEmailState state) {
    final requesting = state is LinkEmailRequesting;
    final entry = state is LinkEmailEntry ? state : null;
    final notifier = ref.read(linkEmailFlowProvider.notifier);
    if (entry != null && _email.text.isEmpty && entry.email.isNotEmpty) {
      _email.text = entry.email;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Link an email to recover your home if you change devices or '
          'reinstall the app. We will send you a 6-digit code.',
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
          onSubmitted: requesting ? null : notifier.requestCode,
        ),
        if (entry?.failure != null) _error(linkEmailMessage(entry!.failure!)),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: requesting
              ? null
              : () => notifier.requestCode(_email.text),
          child: requesting ? const _Spinner() : const Text('Send code'),
        ),
      ],
    );
  }

  Widget _codeStep(LinkEmailState state) {
    final notifier = ref.read(linkEmailFlowProvider.notifier);
    final entry = state is LinkEmailCodeEntry ? state : null;
    final email = entry?.email ?? (state as LinkEmailVerifying).email;
    final verifying = state is LinkEmailVerifying;
    final busy = verifying || (entry?.isResending ?? false);
    final remaining = entry == null
        ? Duration.zero
        : entry.resendAvailableAt.difference(ref.read(recoveryClockProvider)());
    final canResend = entry != null && notifier.canResend(entry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'We sent a 6-digit code to $email. Enter it to finish. Your account '
          'is not protected until then.',
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
          onSubmitted: busy ? null : (_) => _submit(notifier),
        ),
        if (entry?.failure != null) _error(linkEmailMessage(entry!.failure!)),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: busy || _code.text.length != 6
              ? null
              : () => _submit(notifier),
          child: verifying ? const _Spinner() : const Text('Verify email'),
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

  Widget _done(LinkEmailDone state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Your account is protected.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '${state.identity.email} is verified. You can sign in with it on '
          'another device.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _submit(LinkEmailFlowNotifier notifier) async {
    final code = _code.text;
    // The code lives only in the field and this call; it is cleared at once.
    _code.clear();
    await notifier.verify(code);
  }

  Widget _error(String message) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5),
  );
}
