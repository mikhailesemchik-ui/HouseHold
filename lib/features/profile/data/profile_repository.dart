import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/profile/domain/profile.dart';

class ProfileRepository {
  const ProfileRepository(this._client);

  final SupabaseClient _client;

  Future<Profile?> fetchProfile(String userId) async {
    final rows = await _client
        .from('profiles')
        .select()
        .eq('user_id', userId)
        .limit(1);
    if (rows.isEmpty) return null;
    return Profile.fromMap(rows.first);
  }

  /// Ensures a profile exists for [userId], creating one if needed.
  /// Safe to call multiple times — idempotent.
  Future<Profile> ensureProfile(String userId) async {
    final existing = await fetchProfile(userId);
    if (existing != null) return existing;

    final publicId = _generatePublicId();
    final displayName = 'User-${publicId.split('-').first}';

    try {
      final data = await _client
          .from('profiles')
          .insert({
            'user_id': userId,
            'public_id': publicId,
            'display_name': displayName,
          })
          .select()
          .single();
      return Profile.fromMap(data);
    } on PostgrestException catch (e) {
      // Race condition: profile was inserted between fetch and insert.
      if (e.code == '23505') {
        final profile = await fetchProfile(userId);
        if (profile != null) return profile;
      }
      rethrow;
    }
  }

  static String _generatePublicId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    String part() =>
        List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
    return '${part()}-${part()}';
  }
}
