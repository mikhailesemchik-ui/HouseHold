import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';

/// Changes which user this device is signed in as, and cleans what the previous
/// user left behind. It has no UI and no caller yet: whoever offers "I already
/// have an account" or "Sign out" must first obtain the user's explicit
/// decision and pass it as [acknowledgeAnonymousLoss].
///
/// Guarantees:
/// - an anonymous user with no recovery email is never replaced or signed out
///   without that acknowledgement (checked before anything is touched);
/// - no data moves between users: ids and F13 request ids are never rewritten,
///   and the previous user's pending financial requests stay under their own
///   user-scoped keys, where another identity can neither read nor replay them
///   (the server also binds every request to the signed-in user);
/// - device state that belongs to a user (reminders, home-screen widget, the
///   push token row) is cleared; app-wide settings are left alone;
/// - [onIdentityChanged] must drop all user-scoped app state. Invalidating a
///   few providers is not enough: the app needs a root scope keyed by user id.
class SessionSwitchCoordinator {
  SessionSwitchCoordinator({
    required EmailAccountRepository repository,
    required SessionSwitchMarker marker,
    required Future<void> Function() unregisterPushToken,
    required Future<void> Function() restorePushRegistration,
    required Future<void> Function() clearDeviceData,
    required void Function() onIdentityChanged,
  }) : _repository = repository,
       _marker = marker,
       _unregisterPushToken = unregisterPushToken,
       _restorePushRegistration = restorePushRegistration,
       _clearDeviceData = clearDeviceData,
       _onIdentityChanged = onIdentityChanged;

  final EmailAccountRepository _repository;
  final SessionSwitchMarker _marker;
  final Future<void> Function() _unregisterPushToken;
  final Future<void> Function() _restorePushRegistration;
  final Future<void> Function() _clearDeviceData;
  final void Function() _onIdentityChanged;

  /// Signs in to an existing account with an emailed code.
  Future<AuthIdentity> recover({
    required String email,
    required String code,
    bool acknowledgeAnonymousLoss = false,
  }) async {
    _repository.assertCanReplaceSession(
      acknowledgeAnonymousLoss: acknowledgeAnonymousLoss,
    );
    final previous = _repository.currentUserId;
    await _begin(previous);
    try {
      final identity = await _repository.verifyRecoveryCode(
        email: email,
        code: code,
        acknowledgeAnonymousLoss: acknowledgeAnonymousLoss,
      );
      await _finish(previous, identity.userId);
      return identity;
    } catch (_) {
      // Rejected code or network failure leave the session as it was; an
      // inactive account was signed in and out again. Either way, settle.
      await _finish(previous, _repository.currentUserId);
      rethrow;
    }
  }

  /// Ends this device's session (other devices stay signed in).
  Future<void> signOut({bool acknowledgeAnonymousLoss = false}) async {
    final previous = _repository.currentUserId;
    if (previous == null) return;
    await _repository.assertCanSignOut(
      acknowledgeAnonymousLoss: acknowledgeAnonymousLoss,
    );
    await _begin(previous);
    try {
      await _repository.signOutLocal();
    } catch (_) {
      await _finish(previous, _repository.currentUserId);
      rethrow;
    }
    await _finish(previous, null);
  }

  /// Marks the switch and removes the previous user's push registration. That
  /// needs the previous user's session, so it runs before anything changes. If
  /// it fails the switch does not happen: leaving the token behind would keep
  /// delivering the previous user's private notifications to this device.
  Future<void> _begin(String? previous) async {
    if (previous == null) return;
    await _marker.mark(previous);
    try {
      await _unregisterPushToken();
    } catch (_) {
      await _marker.clear();
      throw const EmailAuthException(EmailAuthFailure.pushCleanupFailed);
    }
  }

  Future<void> _finish(String? previous, String? now) async {
    if (previous == now) {
      // Nothing changed (rejected code, offline): the user keeps their own
      // notifications, which were switched off in advance.
      if (previous != null) {
        try {
          await _restorePushRegistration();
        } catch (_) {
          // Retried by the next launch's sync.
        }
      }
      await _marker.clear();
      return;
    }
    _onIdentityChanged();
    try {
      await _clearDeviceData();
    } catch (_) {
      return; // the marker stays, so the next launch repeats the cleanup
    }
    await _marker.clear();
  }
}
