import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
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

/// The signed-in user's profile. It never signs anyone in: an anonymous
/// account is created only by the welcome screen's explicit choice, and
/// interrupted cleanups run in the startup flow before this is first read.
final currentProfileProvider = FutureProvider<Profile>((ref) async {
  final client = supabaseClient;
  final user = client.auth.currentUser;
  if (user == null) {
    throw StateError('No signed-in user.');
  }
  return ProfileRepository(client).ensureProfile(user.id);
});
