import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'household_updates_push_settings.dart';
import 'remote_notification_payload.dart';

class DevicePushTokenRegistration {
  const DevicePushTokenRegistration({
    required this.userId,
    required this.token,
    required this.platform,
  });

  final String userId;
  final String token;
  final String platform;

  Map<String, Object?> toMap() => {
    'user_id': userId,
    'token': token,
    'platform': platform,
  };
}

abstract class PushTokenProvider {
  Future<String?> getToken();

  String? get platform;
}

class MethodChannelPushTokenProvider implements PushTokenProvider {
  const MethodChannelPushTokenProvider();

  static const _channel = MethodChannel('household_os/push_token');

  @override
  String? get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return null;
  }

  @override
  Future<String?> getToken() async {
    try {
      final token = await _channel.invokeMethod<String>('getPushToken');
      if (token == null || token.trim().isEmpty) return null;
      return token.trim();
    } on MissingPluginException {
      return null;
    }
  }
}

class SupabaseDevicePushTokenRegistrar {
  const SupabaseDevicePushTokenRegistrar(this._client);

  final SupabaseClient _client;

  Future<void> registerCurrentUserToken({
    required String token,
    required String platform,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');

    final registration = DevicePushTokenRegistration(
      userId: userId,
      token: token,
      platform: platform,
    );
    await _client
        .from('device_push_tokens')
        .upsert(registration.toMap(), onConflict: 'user_id,token');
  }

  Future<void> unregisterCurrentUserToken(String token) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    await _client
        .from('device_push_tokens')
        .delete()
        .eq('user_id', userId)
        .eq('token', token);
  }
}

abstract class HouseholdUpdatesPushPreferenceStore {
  Future<bool> isEnabled();

  Future<void> setEnabled(bool value);

  Future<String?> lastRegisteredToken();

  Future<void> setLastRegisteredToken(String? token);
}

class SharedPreferencesHouseholdUpdatesPushPreferenceStore
    implements HouseholdUpdatesPushPreferenceStore {
  const SharedPreferencesHouseholdUpdatesPushPreferenceStore();

  @override
  Future<bool> isEnabled() => HouseholdUpdatesPushSettings.isEnabled();

  @override
  Future<void> setEnabled(bool value) =>
      HouseholdUpdatesPushSettings.setEnabled(value);

  @override
  Future<String?> lastRegisteredToken() =>
      HouseholdUpdatesPushSettings.lastRegisteredToken();

  @override
  Future<void> setLastRegisteredToken(String? token) =>
      HouseholdUpdatesPushSettings.setLastRegisteredToken(token);
}

class HouseholdUpdatesPushController {
  const HouseholdUpdatesPushController({
    required this.tokenProvider,
    required this.preferenceStore,
    required this.registerToken,
    required this.unregisterToken,
    required this.requestPermission,
  });

  final PushTokenProvider tokenProvider;
  final HouseholdUpdatesPushPreferenceStore preferenceStore;
  final Future<void> Function(String token, String platform) registerToken;
  final Future<void> Function(String token) unregisterToken;
  final Future<bool> Function() requestPermission;

  Future<bool> setEnabled(bool enabled) async {
    if (!enabled) {
      await preferenceStore.setEnabled(false);
      final previousToken = await preferenceStore.lastRegisteredToken();
      if (previousToken != null) {
        await unregisterToken(previousToken);
      }
      await preferenceStore.setLastRegisteredToken(null);
      return false;
    }

    final granted = await requestPermission();
    if (!granted) return false;

    final platform = tokenProvider.platform;
    final token = await tokenProvider.getToken();
    if (platform == null || token == null) return false;

    await registerToken(token, platform);
    final previousToken = await preferenceStore.lastRegisteredToken();
    if (previousToken != null && previousToken != token) {
      await unregisterToken(previousToken);
    }
    await preferenceStore.setLastRegisteredToken(token);
    await preferenceStore.setEnabled(true);
    return true;
  }
}

class RemotePushNotificationService {
  RemotePushNotificationService({PushTokenProvider? tokenProvider})
    : tokenProvider = tokenProvider ?? const MethodChannelPushTokenProvider();

  static const _tapChannel = MethodChannel('household_os/push_notifications');

  final PushTokenProvider tokenProvider;

  Future<void> initialize({required void Function(String route) onNavigate}) {
    _tapChannel.setMethodCallHandler((call) async {
      if (call.method != 'notificationTapped') return;
      final payload = RemoteNotificationPayload.tryParse(call.arguments);
      final route = payload?.route;
      if (route != null) onNavigate(route);
    });
    return Future.value();
  }

  /// Returns the payload from a notification that cold-launched the app, if any.
  /// Returns null if the app was not launched via a notification tap.
  Future<RemoteNotificationPayload?> getLaunchPayload() async {
    try {
      final raw = await _tapChannel.invokeMethod<Object?>('getLaunchPayload');
      if (raw == null) return null;
      return RemoteNotificationPayload.tryParse(raw);
    } on MissingPluginException {
      return null;
    } catch (e, st) {
      debugPrint('getLaunchPayload error: $e\n$st');
      return null;
    }
  }
}
