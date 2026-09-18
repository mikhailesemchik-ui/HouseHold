import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/remote_notification_payload.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';

class _FakeTokenProvider implements PushTokenProvider {
  const _FakeTokenProvider({this.token, this.platformValue = 'android'});

  final String? token;
  final String? platformValue;

  @override
  String? get platform => platformValue;

  @override
  Future<String?> getToken() async => token;
}

class _FakeStore implements HouseholdUpdatesPushPreferenceStore {
  bool enabled;
  String? token;

  _FakeStore({this.enabled = false, this.token});

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<String?> lastRegisteredToken() async => token;

  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
  }

  @override
  Future<void> setLastRegisteredToken(String? value) async {
    token = value;
  }
}

void main() {
  group('HouseholdUpdatesPushController', () {
    test('disabled preference does not register token', () async {
      var registerCount = 0;
      String? unregisteredToken;
      final store = _FakeStore(enabled: true, token: 'old-token');
      final controller = HouseholdUpdatesPushController(
        tokenProvider: const _FakeTokenProvider(token: 'new-token'),
        preferenceStore: store,
        registerToken: (token, platform) async => registerCount++,
        unregisterToken: (token) async => unregisteredToken = token,
        requestPermission: () async => true,
      );

      final enabled = await controller.setEnabled(false);

      expect(enabled, isFalse);
      expect(store.enabled, isFalse);
      expect(registerCount, 0);
      expect(unregisteredToken, 'old-token');
      expect(store.token, isNull);
    });

    test('registers current device token and removes rotated token', () async {
      final store = _FakeStore(token: 'old-token');
      final registrations = <DevicePushTokenRegistration>[];
      String? unregisteredToken;
      final controller = HouseholdUpdatesPushController(
        tokenProvider: const _FakeTokenProvider(token: 'new-token'),
        preferenceStore: store,
        registerToken: (token, platform) async {
          registrations.add(
            DevicePushTokenRegistration(
              userId: 'current-user',
              token: token,
              platform: platform,
            ),
          );
        },
        unregisterToken: (token) async => unregisteredToken = token,
        requestPermission: () async => true,
      );

      final enabled = await controller.setEnabled(true);

      expect(enabled, isTrue);
      expect(store.enabled, isTrue);
      expect(store.token, 'new-token');
      expect(unregisteredToken, 'old-token');
      expect(registrations.single.toMap(), {
        'user_id': 'current-user',
        'token': 'new-token',
        'platform': 'android',
      });
    });

    test('does not enable when permission is denied', () async {
      var registered = false;
      final store = _FakeStore();
      final controller = HouseholdUpdatesPushController(
        tokenProvider: const _FakeTokenProvider(token: 'token'),
        preferenceStore: store,
        registerToken: (token, platform) async => registered = true,
        unregisterToken: (token) async {},
        requestPermission: () async => false,
      );

      final enabled = await controller.setEnabled(true);

      expect(enabled, isFalse);
      expect(store.enabled, isFalse);
      expect(registered, isFalse);
    });

    test('does not enable when no push token is available', () async {
      var registered = false;
      final store = _FakeStore();
      final controller = HouseholdUpdatesPushController(
        tokenProvider: const _FakeTokenProvider(token: null),
        preferenceStore: store,
        registerToken: (token, platform) async => registered = true,
        unregisterToken: (token) async {},
        requestPermission: () async => true,
      );

      final enabled = await controller.setEnabled(true);

      expect(enabled, isFalse);
      expect(store.enabled, isFalse);
      expect(registered, isFalse);
    });
    test('does not enable when platform is unsupported', () async {
      var registered = false;
      final store = _FakeStore();
      final controller = HouseholdUpdatesPushController(
        tokenProvider: const _FakeTokenProvider(
          token: 'token',
          platformValue: null,
        ),
        preferenceStore: store,
        registerToken: (token, platform) async => registered = true,
        unregisterToken: (token) async {},
        requestPermission: () async => true,
      );

      final enabled = await controller.setEnabled(true);

      expect(enabled, isFalse);
      expect(store.enabled, isFalse);
      expect(registered, isFalse);
    });
  });

  group('DevicePushTokenRegistration', () {
    test('payload uses supplied current user only', () {
      const registration = DevicePushTokenRegistration(
        userId: 'current-user',
        token: 'device-token',
        platform: 'ios',
      );

      expect(registration.toMap(), {
        'user_id': 'current-user',
        'token': 'device-token',
        'platform': 'ios',
      });
    });
  });

  group('RemoteNotificationPayload', () {
    test('parses notification payload', () {
      final payload = RemoteNotificationPayload.fromMap({
        'type': 'task_assigned',
        'householdId': 'hh-1',
        'taskId': 'task-1',
      });

      expect(payload.type, 'task_assigned');
      expect(payload.householdId, 'hh-1');
      expect(payload.taskId, 'task-1');
    });

    test('maps task assignment to household tasks route', () {
      final payload = RemoteNotificationPayload.fromMap({
        'type': 'task_assigned',
        'householdId': 'hh-1',
      });

      expect(payload.route, '/homes/hh-1/tasks');
    });

    test(
      'maps household_joined and ownership_transferred to household dashboard',
      () {
        for (final type in ['household_joined', 'ownership_transferred']) {
          final payload = RemoteNotificationPayload.fromMap({
            'type': type,
            'householdId': 'hh-1',
          });
          expect(payload.route, '/homes/hh-1');
        }
      },
    );

    test('maps member_removed to homes list (user lost access)', () {
      final payload = RemoteNotificationPayload.fromMap({
        'type': 'member_removed',
        'householdId': 'hh-1',
      });
      expect(payload.route, '/homes');
    });

    test('unknown notification type has no navigation target', () {
      final payload = RemoteNotificationPayload.fromMap({
        'type': 'unknown',
        'householdId': 'hh-1',
      });

      expect(payload.route, isNull);
    });

    test('missing household id has no navigation target', () {
      final payload = RemoteNotificationPayload.fromMap({
        'type': 'task_assigned',
      });

      expect(payload.route, isNull);
    });
  });
}
