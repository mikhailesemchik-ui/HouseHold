import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/data/session_switch_coordinator.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final emailAccountRepositoryProvider = Provider<EmailAccountRepository>((ref) {
  return EmailAccountRepository(SupabaseAuthPort(supabaseClient));
});

/// Not used by any screen yet. Before a screen calls it, the app needs a root
/// scope keyed by the signed-in user id: the invalidations below only cover the
/// providers that exist at the top level today.
final sessionSwitchCoordinatorProvider =
    FutureProvider<SessionSwitchCoordinator>((ref) async {
      final prefs = await SharedPreferences.getInstance();
      return SessionSwitchCoordinator(
        repository: ref.watch(emailAccountRepositoryProvider),
        marker: SessionSwitchMarker(prefs),
        unregisterPushToken: _unregisterPushTokenOfCurrentUser,
        clearDeviceData: clearRemindersAndWidget,
        onIdentityChanged: () {
          ref.invalidate(currentProfileProvider);
          ref.invalidate(homesProvider);
        },
      );
    });

Future<void> _unregisterPushTokenOfCurrentUser() async {
  final token = await HouseholdUpdatesPushSettings.lastRegisteredToken();
  if (token == null) return;
  await SupabaseDevicePushTokenRegistrar(
    supabaseClient,
  ).unregisterCurrentUserToken(token);
  await HouseholdUpdatesPushSettings.setLastRegisteredToken(null);
}
