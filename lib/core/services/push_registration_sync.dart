import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';

/// Makes this device's push token belong to the signed-in user, if that user
/// opted in.
///
/// Ownership is never inferred from a device-wide flag: it comes from the
/// opt-in recorded for exactly this user id. The call is idempotent (an upsert
/// on `(user_id, token)`), so it is safe at every launch and after a switch;
/// it also moves the user's own registration to a rotated token.
///
/// It never asks for permission, registers nothing for a user who has not
/// opted in, and does nothing while an account deletion is unresolved for the
/// user. It only ever touches the signed-in user's rows (row level security
/// allows nothing else). Errors are thrown so the caller can decide; a failed
/// run reports no success.
class PushRegistrationSync {
  PushRegistrationSync({
    required this.currentUserId,
    required this.tokenProvider,
    required this.registerToken,
    required this.unregisterToken,
    required this.isDeletionPending,
  });

  final String? Function() currentUserId;
  final PushTokenProvider tokenProvider;
  final Future<void> Function(String token, String platform) registerToken;
  final Future<void> Function(String token) unregisterToken;

  /// Whether a local account-deletion marker names this user.
  final Future<bool> Function(String userId) isDeletionPending;

  Future<void> ensureRegistered(String userId) async {
    // The session may have changed since the caller decided to sync.
    if (currentUserId() != userId) return;
    final settings = HouseholdUpdatesPushSettings.forUser(userId);
    if (!await settings.isEnabled()) return;
    if (await isDeletionPending(userId)) return;

    final platform = tokenProvider.platform;
    final token = await tokenProvider.getToken();
    if (platform == null || token == null) return;
    if (currentUserId() != userId) return;

    await registerToken(token, platform);
    final previous = await settings.lastRegisteredToken();
    if (previous != null && previous != token) {
      await unregisterToken(previous);
    }
    await settings.setLastRegisteredToken(token);
  }
}
