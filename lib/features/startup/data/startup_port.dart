import 'package:household_os/features/auth/data/session_switch_marker.dart';
import 'package:household_os/features/profile/data/account_local_cleanup.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What startup needs from the outside world, so the state machine can be
/// tested without a server.
abstract interface class StartupPort {
  /// Whether a session was restored from this device's storage. Supabase loads
  /// it before `runApp`, so `false` really means "no session", not "not yet".
  bool get hasSession;

  /// Finishes an interrupted account deletion and an interrupted user switch.
  /// Throws if either could not be completed.
  Future<void> resumePendingCleanup();

  Future<void> signInAnonymously();

  /// The signed-in user's profile (created on first use). Never signs in.
  Future<Profile> loadProfile();

  /// Registers this device's push token for [profile]'s user if they opted in.
  /// Best effort and idempotent; throws on failure.
  Future<void> syncPushRegistration(Profile profile);
}

class SupabaseStartupPort implements StartupPort {
  const SupabaseStartupPort(
    this._client, {
    required Future<Profile> Function() loadProfile,
    Future<void> Function() clearDeviceData = clearRemindersAndWidget,
    Future<void> Function(Profile profile)? syncPushRegistration,
  }) : _loadProfile = loadProfile,
       _clearDeviceData = clearDeviceData,
       _syncPushRegistration = syncPushRegistration;

  final SupabaseClient _client;
  final Future<Profile> Function() _loadProfile;
  final Future<void> Function() _clearDeviceData;
  final Future<void> Function(Profile profile)? _syncPushRegistration;

  @override
  bool get hasSession => _client.auth.currentSession != null;

  @override
  Future<void> resumePendingCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    Object? failure;
    try {
      await AccountLocalCleanup(
        prefs,
        clearDeviceData: _clearDeviceData,
      ).resumeIfPending(AccountRepository(_client));
    } catch (e) {
      failure = e;
    }
    try {
      await SessionSwitchMarker(prefs).resumeIfPending(
        currentUserId: _client.auth.currentUser?.id,
        clearDeviceData: _clearDeviceData,
      );
    } catch (e) {
      failure ??= e;
    }
    if (failure != null) throw failure;
  }

  @override
  Future<void> signInAnonymously() async {
    await _client.auth.signInAnonymously();
  }

  @override
  Future<Profile> loadProfile() => _loadProfile();

  @override
  Future<void> syncPushRegistration(Profile profile) async {
    await _syncPushRegistration?.call(profile);
  }
}
