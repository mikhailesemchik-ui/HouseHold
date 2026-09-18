import 'dart:math';
import 'dart:typed_data';

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

  /// Updates the display name for [userId]. Caller must validate before calling.
  Future<Profile> updateDisplayName(String userId, String displayName) async {
    final data = await _client
        .from('profiles')
        .update({'display_name': displayName})
        .eq('user_id', userId)
        .select()
        .single();
    return Profile.fromMap(data);
  }

  /// Uploads avatar bytes to storage and returns the public URL.
  Future<String> uploadAvatar(
    String userId,
    Uint8List bytes,
    String mimeType,
    String ext,
  ) async {
    final path = '$userId/avatar.$ext';
    await _client.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: mimeType),
        );
    return _client.storage.from('avatars').getPublicUrl(path);
  }

  /// Sets or clears the avatar URL on the profile row.
  Future<Profile> setAvatarUrl(String userId, String? url) async {
    final data = await _client
        .from('profiles')
        .update({'avatar_url': url})
        .eq('user_id', userId)
        .select()
        .single();
    return Profile.fromMap(data);
  }

  /// Deletes all avatar files for [userId] from storage. Best-effort.
  Future<void> deleteAvatarFiles(String userId) async {
    try {
      final files = await _client.storage.from('avatars').list(path: userId);
      if (files.isNotEmpty) {
        final paths = files.map((f) => '$userId/${f.name}').toList();
        await _client.storage.from('avatars').remove(paths);
      }
    } catch (_) {
      // Best-effort: storage cleanup should not fail the profile update.
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
