import 'package:supabase_flutter/supabase_flutter.dart';

/// Why an email-linking or recovery step did not complete. Safe to show: it
/// never carries a code, token or server message.
enum EmailAuthFailure {
  invalidEmail,
  emailInUse,

  /// Wrong, expired, already used or malformed code. The server answers all of
  /// these the same way, so they cannot be told apart.
  codeRejected,
  rateLimited,
  network,
  serverError,
  notSignedIn,

  /// The signed-in user is already a permanent (email) user.
  alreadyLinked,

  /// The user changed between asking for a code and entering it.
  sessionChanged,
  accountNotActive,

  /// The action would discard an anonymous account that has no recovery email.
  anonymousAccountAtRisk,

  /// The server answered, but not with the identity that was expected.
  identityMismatch,
}

class EmailAuthException implements Exception {
  const EmailAuthException(this.failure);

  final EmailAuthFailure failure;

  @override
  String toString() => 'EmailAuthException($failure)';
}

/// Which request a server error belongs to; the same server code means
/// different things when asking for a code and when checking one.
enum EmailAuthStep { requestCode, verifyCode }

/// Maps SDK and transport errors to [EmailAuthFailure].
EmailAuthFailure mapEmailAuthError(Object error, EmailAuthStep step) {
  if (error is EmailAuthException) return error.failure;
  if (error is AuthSessionMissingException) return EmailAuthFailure.notSignedIn;
  if (error is AuthRetryableFetchException) return EmailAuthFailure.network;
  if (error is AuthApiException) {
    final code = error.code ?? '';
    final status = error.statusCode ?? '';
    if (code == 'email_exists' || code == 'user_already_exists') {
      return EmailAuthFailure.emailInUse;
    }
    if (status == '429' || code.startsWith('over_')) {
      return EmailAuthFailure.rateLimited;
    }
    if (step == EmailAuthStep.verifyCode &&
        (code == 'otp_expired' || code == 'validation_failed')) {
      return EmailAuthFailure.codeRejected;
    }
    if (step == EmailAuthStep.requestCode &&
        (code == 'validation_failed' || code.startsWith('email_address_'))) {
      return EmailAuthFailure.invalidEmail;
    }
    return EmailAuthFailure.serverError;
  }
  if (error is AuthException) return EmailAuthFailure.serverError;
  // Socket / HTTP client failures surface as non-Auth exceptions.
  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup')) {
    return EmailAuthFailure.network;
  }
  return EmailAuthFailure.serverError;
}
