import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/recovery_screen.dart';
import 'package:household_os/features/profile/data/account_repository.dart';

const deleteAccountPhrase = 'DELETE';
const _codeLength = 6;
const _resendCooldown = Duration(seconds: 60);

String _failureMessage(AccountDeletionFailure failure) => switch (failure) {
  AccountDeletionFailure.ownsHouseholds =>
    'You still own a home. Transfer or delete it first.',
  AccountDeletionFailure.codeRejected =>
    "That code didn't work. Check it, or request a new one.",
  AccountDeletionFailure.rateLimited =>
    'Too many attempts. Please wait a moment and try again.',
  AccountDeletionFailure.tooManyAttempts =>
    'Too many verification attempts. Please try again later.',
  AccountDeletionFailure.verificationUnavailable =>
    "We couldn't check the code right now. Try again in a moment.",
  AccountDeletionFailure.sessionChanged =>
    'Your account changed. Close this and start again.',
  AccountDeletionFailure.verificationRequired =>
    'Enter the code we emailed you.',
  AccountDeletionFailure.retryable =>
    'Deleting did not finish. Your account is not usable any more, so please '
        'try again.',
};

/// "Delete account": a typed confirmation and, for an email-linked account, a
/// second step with an emailed code. Whether the code is needed is decided by
/// the server (the first request is refused with `verificationRequired`), so
/// nothing is sent or mailed just by opening the dialog.
///
/// [onDelete] sends the request and returns only when the server confirmed
/// the deletion; [onRequestCode] emails a fresh code. The code is only held in
/// the text field and passed to [onDelete]; it is cleared at once.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({
    super.key,
    required this.resuming,
    required this.onDelete,
    required this.onRequestCode,
  });

  final bool resuming;
  final Future<void> Function(String? code) onDelete;
  final Future<void> Function() onRequestCode;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _phrase = TextEditingController();
  final _code = TextEditingController();
  Timer? _ticker;
  bool _isBusy = false;
  bool _isCodeStep = false;
  bool _canRetryWithoutCode = false;
  DateTime? _resendAvailableAt;
  String? _error;

  bool get _phraseMatches => _phrase.text == deleteAccountPhrase;
  bool get _canResend =>
      !_isBusy &&
      (_resendAvailableAt == null ||
          !DateTime.now().isBefore(_resendAvailableAt!));

  @override
  void initState() {
    super.initState();
    // The cooldown is a timestamp, so it stays right across backgrounding.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isCodeStep) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _phrase.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _delete({String? code}) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await widget.onDelete(code);
      if (mounted) Navigator.of(context).pop(true);
    } on AccountDeletionException catch (e) {
      await _onFailure(e.failure);
    } catch (_) {
      if (mounted) _fail(_failureMessage(AccountDeletionFailure.retryable));
    }
  }

  Future<void> _onFailure(AccountDeletionFailure failure) async {
    if (!mounted) return;
    if (failure == AccountDeletionFailure.verificationRequired &&
        !_isCodeStep) {
      setState(() {
        _isCodeStep = true;
        _isBusy = false;
      });
      await _sendCode();
      return;
    }
    if (failure == AccountDeletionFailure.retryable && _isCodeStep) {
      // The server may already have started: a retry needs no new code.
      _canRetryWithoutCode = true;
    }
    _fail(_failureMessage(failure));
  }

  void _fail(String message) {
    setState(() {
      _isBusy = false;
      _error = message;
    });
  }

  Future<void> _sendCode() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await widget.onRequestCode();
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _resendAvailableAt = DateTime.now().add(_resendCooldown);
      });
    } on EmailAuthException catch (e) {
      if (mounted) _fail(recoveryMessage(e.failure));
    } on AccountDeletionException catch (e) {
      if (mounted) _fail(_failureMessage(e.failure));
    } catch (_) {
      if (mounted) _fail(recoveryMessage(EmailAuthFailure.serverError));
    }
  }

  void _submitCode() {
    final code = _code.text;
    _code.clear(); // never kept after it was sent
    setState(() {});
    _delete(code: code);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.resuming ? 'Finish deleting account?' : 'Delete account?',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._consequences(),
            const SizedBox(height: 12),
            if (_isCodeStep) ..._codeStep() else ..._confirmStep(),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _primaryAction(),
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          child: _isBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_canRetryWithoutCode ? 'Try again' : 'Delete account'),
        ),
      ],
    );
  }

  VoidCallback? _primaryAction() {
    if (_isBusy) return null;
    if (!_isCodeStep) return _phraseMatches ? _delete : null;
    if (_canRetryWithoutCode) return _delete;
    return _code.text.length == _codeLength ? _submitCode : null;
  }

  List<Widget> _consequences() => const [
    Text(
      'Your account, name, avatar and notification settings are '
      'permanently deleted. This cannot be undone and you cannot sign '
      'back in to this account.',
    ),
    SizedBox(height: 8),
    Text(
      'Shared homes keep their tasks, shopping and expenses. Entries '
      'you made stay as "Deleted member" for the other members, and '
      'any text you wrote in them is kept.',
    ),
    SizedBox(height: 8),
    Text(
      'Open balances with other members can no longer be settled '
      'with you. Payments are not forgiven or changed.',
    ),
  ];

  List<Widget> _confirmStep() => [
    Text('Type $deleteAccountPhrase to confirm.'),
    const SizedBox(height: 8),
    TextField(
      controller: _phrase,
      enabled: !_isBusy,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Confirmation'),
      onChanged: (_) => setState(() {}),
    ),
  ];

  List<Widget> _codeStep() {
    final remaining = _resendAvailableAt?.difference(DateTime.now());
    return [
      const Text(
        'We emailed a 6-digit code to your account email. Entering it '
        'confirms this is your account.',
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _code,
        enabled: !_isBusy && !_canRetryWithoutCode,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(_codeLength),
        ],
        decoration: const InputDecoration(labelText: '6-digit code'),
        onChanged: (_) => setState(() {}),
      ),
      TextButton(
        onPressed: _canResend && !_canRetryWithoutCode ? _sendCode : null,
        child: Text(
          _canResend || remaining == null
              ? 'Send a new code'
              : 'Send a new code in ${remaining.inSeconds + 1}s',
        ),
      ),
    ];
  }
}
