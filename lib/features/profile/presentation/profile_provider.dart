import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/profile/data/profile_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';

final currentProfileProvider = FutureProvider<Profile>((ref) async {
  final client = supabaseClient;

  if (client.auth.currentSession == null) {
    await client.auth.signInAnonymously();
  }

  final user = client.auth.currentUser;
  if (user == null) {
    throw StateError('Authentication failed unexpectedly.');
  }

  return ProfileRepository(client).ensureProfile(user.id);
});
