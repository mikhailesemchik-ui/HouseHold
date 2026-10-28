import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:household_os/features/profile/data/profile_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(supabaseClient);
});

final accountLocalCleanupProvider = FutureProvider<AccountLocalCleanup>((
  ref,
) async {
  return AccountLocalCleanup(await SharedPreferences.getInstance());
});

final currentProfileProvider = FutureProvider<Profile>((ref) async {
  final client = supabaseClient;

  // Finish a local cleanup interrupted by an app kill, before any new
  // anonymous account can be created.
  try {
    final cleanup = await ref.read(accountLocalCleanupProvider.future);
    await cleanup.resumeIfPending(ref.read(accountRepositoryProvider));
  } catch (_) {
    // Retried on the next launch; never blocks loading the profile.
  }

  // Finish a user switch or sign-out that was cut short by an app kill.
  try {
    await SessionSwitchMarker(
      await SharedPreferences.getInstance(),
    ).resumeIfPending(
      currentUserId: client.auth.currentUser?.id,
      clearDeviceData: clearRemindersAndWidget,
    );
  } catch (_) {
    // Retried on the next launch.
  }

  if (client.auth.currentSession == null) {
    await client.auth.signInAnonymously();
  }

  final user = client.auth.currentUser;
  if (user == null) {
    throw StateError('Authentication failed unexpectedly.');
  }

  return ProfileRepository(client).ensureProfile(user.id);
});
