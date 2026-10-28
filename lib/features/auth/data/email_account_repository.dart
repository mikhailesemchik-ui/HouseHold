import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Attaches a verified email to the CURRENT anonymous user (same auth.uid)
/// and restores that user on another device with an emailed code.
///
/// Verified against local Auth (see `test_local_auth/`):
/// - link: `updateUser(email)` then `verifyOTP(emailChange)`; the user id is
///   unchanged and stays anonymous until the code is accepted;
/// - recover: `signInWithOtp(shouldCreateUser: false)` then `verifyOTP(email)`;
/// - the SDK's `resend()` sends nothing for this case, so a resend is another
///   `updateUser(email)`, which invalidates the previous code.
///
/// Nothing here ever calls `signInAnonymously`, and no code or token is logged.
class EmailAccountRepository {
  EmailAccountRepository(this._port);

  final AuthPort _port;
  Future<AuthIdentity>? _linkRequest;

  String? get currentUserId => _port.currentUserId;

  /// Server truth about the signed-in user, including a pending email.
  Future<AuthIdentity> currentIdentity() {
    return _guard(EmailAuthStep.verifyCode, () async {
      _requireSignedIn();
      return _port.fetchIdentity();
    });
  }

  /// Sends (or re-sends) the link code to [email]. A sent mail is NOT a
  /// verified email: only [verifyLinkCode] links the account.
  Future<AuthIdentity> sendLinkCode(String email) {
    // A double tap shares one request instead of mailing two codes.
    return _linkRequest ??= _guard(EmailAuthStep.requestCode, () async {
      final address = _normalize(email);
      _requireSignedIn();
      await _requireActiveAccount();
      final identity = await _port.fetchIdentity();
      if (!identity.isAnonymous) {
        throw const EmailAuthException(EmailAuthFailure.alreadyLinked);
      }
      return _port.requestEmailChange(address);
    }).whenComplete(() => _linkRequest = null);
  }

  /// Completes the link. [expectedUserId] is the user the code was requested
  /// for; if the session changed since, nothing is sent to the server.
  Future<AuthIdentity> verifyLinkCode({
    required String expectedUserId,
    required String email,
    required String code,
  }) {
    return _guard(EmailAuthStep.verifyCode, () async {
      final address = _normalize(email);
      final token = _normalizeCode(code);
      if (_port.currentUserId != expectedUserId) {
        throw const EmailAuthException(EmailAuthFailure.sessionChanged);
      }
      final identity = await _port.verifyEmailChange(address, token);
      if (identity.userId != expectedUserId ||
          !identity.isLinked ||
          identity.email?.toLowerCase() != address) {
        throw const EmailAuthException(EmailAuthFailure.identityMismatch);
      }
      return identity;
    });
  }

  /// Asks for a sign-in code for an EXISTING account. An unknown address gets
  /// the same quiet result as a known one, but the server's answers still
  /// differ, so abuse protection must live on the server side.
  Future<void> sendRecoveryCode(String email) async {
    final address = _normalize(email);
    try {
      await _port.requestSignInCode(address);
    } on AuthApiException catch (e) {
      if (e.code == 'otp_disabled') return; // unknown address: no account
      throw EmailAuthException(mapEmailAuthError(e, EmailAuthStep.requestCode));
    } catch (e) {
      throw EmailAuthException(mapEmailAuthError(e, EmailAuthStep.requestCode));
    }
  }

  /// Throws [EmailAuthFailure.anonymousAccountAtRisk] when a session exists
  /// that has no recovery email, unless the caller was told it will be lost.
  void assertCanReplaceSession({required bool acknowledgeAnonymousLoss}) {
    if (_port.currentUserId != null &&
        !_port.cachedUserIsLinked &&
        !acknowledgeAnonymousLoss) {
      throw const EmailAuthException(EmailAuthFailure.anonymousAccountAtRisk);
    }
  }

  /// Signs in with the emailed code. Replaces the current session, so it is
  /// refused for an unlinked anonymous user unless acknowledged.
  Future<AuthIdentity> verifyRecoveryCode({
    required String email,
    required String code,
    bool acknowledgeAnonymousLoss = false,
  }) async {
    final address = _normalize(email);
    final token = _normalizeCode(code);
    assertCanReplaceSession(acknowledgeAnonymousLoss: acknowledgeAnonymousLoss);
    final AuthIdentity identity;
    try {
      identity = await _port.verifySignInCode(address, token);
    } catch (e) {
      throw EmailAuthException(mapEmailAuthError(e, EmailAuthStep.verifyCode));
    }
    if (identity.isAnonymous || !identity.isLinked) {
      throw const EmailAuthException(EmailAuthFailure.identityMismatch);
    }
    await _refuseInactiveAccount();
    return identity;
  }

  /// Server-verified check before ending this device's session: a linked user
  /// can sign back in by email; an unlinked anonymous user cannot, so that
  /// needs explicit acknowledgement. A network failure never signs out.
  Future<void> assertCanSignOut({
    required bool acknowledgeAnonymousLoss,
  }) async {
    if (_port.currentUserId == null) return;
    final identity = await currentIdentity();
    if (!identity.isLinked && !acknowledgeAnonymousLoss) {
      throw const EmailAuthException(EmailAuthFailure.anonymousAccountAtRisk);
    }
  }

  /// Ends only this device's session.
  Future<void> signOutLocal() =>
      _guard(EmailAuthStep.verifyCode, () => _port.signOutLocal());

  // After a successful code the session already exists. A deleting or deleted
  // profile is signed out again (the database refuses it anyway); a failed
  // read keeps the session, because the database enforces access regardless.
  Future<void> _refuseInactiveAccount() async {
    String? state;
    try {
      state = await _port.readAccountState();
    } catch (_) {
      return;
    }
    if (state != null && state != 'active') {
      await _port.signOutLocal();
      throw const EmailAuthException(EmailAuthFailure.accountNotActive);
    }
  }

  Future<void> _requireActiveAccount() async {
    final String? state;
    try {
      state = await _port.readAccountState();
    } catch (e) {
      throw EmailAuthException(mapEmailAuthError(e, EmailAuthStep.requestCode));
    }
    if (state != null && state != 'active') {
      throw const EmailAuthException(EmailAuthFailure.accountNotActive);
    }
  }

  void _requireSignedIn() {
    if (_port.currentUserId == null) {
      throw const EmailAuthException(EmailAuthFailure.notSignedIn);
    }
  }

  Future<T> _guard<T>(EmailAuthStep step, Future<T> Function() action) async {
    try {
      return await action();
    } on EmailAuthException {
      rethrow;
    } catch (e) {
      throw EmailAuthException(mapEmailAuthError(e, step));
    }
  }

  String _normalize(String email) {
    final address = email.trim().toLowerCase();
    final at = address.indexOf('@');
    if (at < 1 || at != address.lastIndexOf('@') || at == address.length - 1) {
      throw const EmailAuthException(EmailAuthFailure.invalidEmail);
    }
    return address;
  }

  String _normalizeCode(String code) {
    final token = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      throw const EmailAuthException(EmailAuthFailure.codeRejected);
    }
    return token;
  }
}
