import 'package:shared_preferences/shared_preferences.dart';

/// The household-updates push opt-in and the token registered for it, kept
/// PER USER. A device-wide flag cannot say whose token was registered, so after
/// an account switch it would show "on" for a user who has no token (and leave
/// the previous user's token receiving their private notifications).
class HouseholdUpdatesPushSettings {
  const HouseholdUpdatesPushSettings._(this._userId);

  /// Settings of one user; other users' entries are never read or changed.
  factory HouseholdUpdatesPushSettings.forUser(String userId) {
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'must not be empty');
    }
    return HouseholdUpdatesPushSettings._(userId);
  }

  final String _userId;

  static const _legacyEnabledKey = 'household_updates_push_enabled';
  static const _legacyTokenKey = 'household_updates_push_token';

  String get _enabledKey => '$_legacyEnabledKey/$_userId';
  String get _tokenKey => '$_legacyTokenKey/$_userId';

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  Future<String?> lastRegisteredToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<void> setLastRegisteredToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  /// Before accounts could change on a device, the opt-in was stored once for
  /// the device, and that device had exactly one user. Hands those values to
  /// the first user who starts the app afterwards, then removes them so they
  /// can never be claimed twice.
  static Future<void> adoptLegacyFor(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_legacyEnabledKey);
    final token = prefs.getString(_legacyTokenKey);
    if (enabled == null && token == null) return;
    final mine = HouseholdUpdatesPushSettings.forUser(userId);
    if (enabled != null && !prefs.containsKey(mine._enabledKey)) {
      await prefs.setBool(mine._enabledKey, enabled);
    }
    if (token != null && !prefs.containsKey(mine._tokenKey)) {
      await prefs.setString(mine._tokenKey, token);
    }
    await prefs.remove(_legacyEnabledKey);
    await prefs.remove(_legacyTokenKey);
  }
}
