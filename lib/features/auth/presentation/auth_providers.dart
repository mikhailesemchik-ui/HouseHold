import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/push_registration_sync.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:shared_preferences/shared_preferences.dart';

final emailAccountRepositoryProvider = Provider<EmailAccountRepository>((ref) {
  return EmailAccountRepository(SupabaseAuthPort(supabaseClient));
});

/// Registers this device's push token for the signed-in user when that user
/// opted in. Used at launch and after a switch that did not happen.
final pushRegistrationSyncProvider = Provider<PushRegistrationSync>((ref) {
  final registrar = SupabaseDevicePushTokenRegistrar(supabaseClient);
  return PushRegistrationSync(
    currentUserId: () => supabaseClient.auth.currentUser?.id,
    tokenProvider: const MethodChannelPushTokenProvider(),
    registerToken: (token, platform) =>
        registrar.registerCurrentUserToken(token: token, platform: platform),
    unregisterToken: registrar.unregisterCurrentUserToken,
    releaseForeignRegistrations: (token, platform) =>
        registrar.releaseForeignRegistrations(token: token, platform: platform),
    isDeletionPending: (userId) async {
      final prefs = await SharedPreferences.getInstance();
      return AccountLocalCleanup(prefs).markedUserId == userId;
    },
  );
});

/// Switches or ends this device's session and cleans the previous user's local
/// state. Dropping the app's user-scoped state is NOT done here: the root
/// `UserScopedRoot` rebuilds the whole provider tree whenever the signed-in
/// user id changes, so the callback below has nothing left to do (and must not
/// touch providers, whose container is being replaced at that moment).
final sessionSwitchCoordinatorProvider =
    FutureProvider<SessionSwitchCoordinator>((ref) async {
      final prefs = await SharedPreferences.getInstance();
      final sync = ref.read(pushRegistrationSyncProvider);
      return SessionSwitchCoordinator(
        repository: ref.watch(emailAccountRepositoryProvider),
        marker: SessionSwitchMarker(prefs),
        unregisterPushToken: _unregisterPushTokenOfCurrentUser,
        restorePushRegistration: () async {
          final userId = supabaseClient.auth.currentUser?.id;
          if (userId != null) await sync.ensureRegistered(userId);
        },
        clearDeviceData: clearRemindersAndWidget,
        onIdentityChanged: () {},
      );
    });

/// Removes the signed-in user's registration of this device. Throws if it
/// could not be removed; the opt-in itself is kept, so the same user is
/// registered again the next time they are signed in here.
Future<void> _unregisterPushTokenOfCurrentUser() async {
  final userId = supabaseClient.auth.currentUser?.id;
  if (userId == null) return;
  final settings = HouseholdUpdatesPushSettings.forUser(userId);
  final token = await settings.lastRegisteredToken();
  if (token == null) return;
  await SupabaseDevicePushTokenRegistrar(
    supabaseClient,
  ).unregisterCurrentUserToken(token);
  await settings.setLastRegisteredToken(null);
}
