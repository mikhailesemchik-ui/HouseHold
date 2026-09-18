import 'package:flutter/foundation.dart';

@immutable
class RemoteNotificationPayload {
  const RemoteNotificationPayload({
    required this.type,
    this.householdId,
    this.taskId,
  });

  final String type;
  final String? householdId;
  final String? taskId;

  factory RemoteNotificationPayload.fromMap(Map<String, Object?> map) {
    return RemoteNotificationPayload(
      type: map['type'] as String? ?? '',
      householdId: map['householdId'] as String?,
      taskId: map['taskId'] as String?,
    );
  }

  static RemoteNotificationPayload? tryParse(Object? value) {
    if (value is Map<String, Object?>) {
      return RemoteNotificationPayload.fromMap(value);
    }
    if (value is Map) {
      return RemoteNotificationPayload.fromMap(
        value.map((key, item) => MapEntry(key.toString(), item)),
      );
    }
    return null;
  }

  String? get route {
    final household = householdId;
    if (household == null || household.isEmpty) return null;

    return switch (type) {
      'task_assigned' => '/homes/$household/tasks',
      // Removed member no longer has access to the household; send to the list.
      'member_removed' => '/homes',
      'household_joined' || 'ownership_transferred' => '/homes/$household',
      _ => null,
    };
  }
}
