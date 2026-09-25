import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Without these receivers Android fires the reminder alarm but nothing
  // shows the notification (NW-001).
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  String receiverBlock(String className) {
    final match = RegExp(
      '<receiver[^>]*android:name="com\\.dexterous\\.flutterlocalnotifications'
      '\\.$className"[^>]*?(/>|>.*?</receiver>)',
      dotAll: true,
    ).firstMatch(manifest);
    expect(match, isNotNull, reason: '$className must be declared');
    return match!.group(0)!;
  }

  test('declares the scheduled notification receiver, not exported', () {
    final block = receiverBlock('ScheduledNotificationReceiver');
    expect(block, contains('android:exported="false"'));
  });

  test('declares the boot receiver with reschedule intent filters', () {
    final block = receiverBlock('ScheduledNotificationBootReceiver');
    expect(block, contains('android:exported="false"'));
    expect(block, contains('android.intent.action.BOOT_COMPLETED'));
    expect(block, contains('android.intent.action.MY_PACKAGE_REPLACED'));
  });
}
