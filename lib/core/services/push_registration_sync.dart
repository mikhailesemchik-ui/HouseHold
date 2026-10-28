import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';

/// Makes this device's push token belong to the signed-in user, if that user
/// opted in.
///
/// Ownership is never inferred from a device-wide flag: it comes from the
/// opt-in recorded for exactly this user id. The server keeps one owner per
/// token, so registering moves the token to this user, and the call is
/// idempotent: safe at every launch and after a switch. It also moves the
/// user's own registration to a rotated token.
///
/// A user who has NOT opted in still asks the server to release this token
/// from any previous owner (a stale registration of an account that lost its
/// session), but registers nothing for themselves.
///
/// It never asks for permission, and does nothing while an account deletion is
/// unresolved for the user. Errors are thrown so the caller can decide; a
/// failed run reports no success.
class PushRegistrationSync {
  PushRegistrationSync({
    required this.currentUserId,
    required this.tokenProvider,
    required this.registerToken,
    required this.unregisterToken,
    required this.releaseForeignRegistrations,
    required this.isDeletionPending,
  });

  final String? Function() currentUserId;
  final PushTokenProvider tokenProvider;
  final Future<void> Function(String token, String platform) registerToken;
  final Future<void> Function(String token) unregisterToken;

  /// Removes the token from other users without registering it for this one.
  final Future<void> Function(String token, String platform)
  releaseForeignRegistrations;

  /// Whether a local account-deletion marker names this user.
  final Future<bool> Function(String userId) isDeletionPending;

  Future<void> ensureRegistered(String userId) async {
    // The session may have changed since the caller decided to sync.
    if (currentUserId() != userId) return;
    if (await isDeletionPending(userId)) return;

    final platform = tokenProvider.platform;
    final token = await tokenProvider.getToken();
    if (platform == null || token == null) return;
    if (currentUserId() != userId) return;

    final settings = HouseholdUpdatesPushSettings.forUser(userId);
    if (!await settings.isEnabled()) {
      await releaseForeignRegistrations(token, platform);
      return;
    }

    await registerToken(token, platform);
    final previous = await settings.lastRegisteredToken();
    if (previous != null && previous != token) {
      await unregisterToken(previous);
    }
    await settings.setLastRegisteredToken(token);
  }
}
