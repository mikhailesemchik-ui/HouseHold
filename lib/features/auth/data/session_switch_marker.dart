import 'package:shared_preferences/shared_preferences.dart';

/// Records that this device is in the middle of leaving one user's session, so
/// a process kill between the sign-in/sign-out and the local cleanup is
/// finished at the next launch. Separate from the account-deletion marker.
class SessionSwitchMarker {
  SessionSwitchMarker(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'session_switch_from_user';

  String? get previousUserId => _prefs.getString(_key);

  Future<void> mark(String previousUserId) =>
      _prefs.setString(_key, previousUserId);

  Future<void> clear() => _prefs.remove(_key);

  /// On launch: if the session really changed, clean up what the previous user
  /// left on the device; if it never changed, just forget the marker. The
  /// cleanup is safe to repeat, and the marker is removed last.
  Future<void> resumeIfPending({
    required String? currentUserId,
    required Future<void> Function() clearDeviceData,
  }) async {
    final previous = previousUserId;
    if (previous == null) return;
    if (currentUserId != previous) {
      await clearDeviceData();
    }
    await clear();
  }
}
