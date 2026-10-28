import 'package:flutter/foundation.dart';
import 'package:household_os/core/utils/member_identity.dart';

@immutable
class TaskEvent {
  const TaskEvent({
    required this.id,
    required this.householdId,
    required this.eventType,
    required this.taskTitle,
    required this.occurredAt,
    this.taskId,
    this.actorUserId,
    this.actorDisplayName,
    this.actorAccountState,
    this.assignedTo,
  });

  final String id;
  final String? taskId;
  final String householdId;
  final String? actorUserId;
  final String? actorDisplayName;
  final String? actorAccountState;
  final String eventType;
  final String taskTitle;
  final String? assignedTo;
  final DateTime occurredAt;

  /// Human-readable description of this event for use in the activity feed.
  /// "Deleted member" only when the account state says so; an actor whose
  /// profile is missing or inaccessible is just "Someone".
  String get displayText {
    final actor = memberNameLabel(
      accountState: actorAccountState,
      displayName: actorDisplayName,
    );
    return switch (eventType) {
      'created' => '$actor created "$taskTitle"',
      'updated' => '$actor updated "$taskTitle"',
      'completed' => '$actor completed "$taskTitle"',
      'reopened' => '$actor reopened "$taskTitle"',
      'deleted' => '$actor deleted "$taskTitle"',
      _ => '$actor changed "$taskTitle"',
    };
  }

  factory TaskEvent.fromMap(Map<String, dynamic> map) {
    final actorProfile = map['actor_profile'] as Map<String, dynamic>?;
    return TaskEvent(
      id: map['id'] as String,
      taskId: map['task_id'] as String?,
      householdId: map['household_id'] as String,
      actorUserId: map['actor_user_id'] as String?,
      actorDisplayName: actorProfile?['display_name'] as String?,
      actorAccountState: actorProfile?['account_state'] as String?,
      eventType: map['event_type'] as String,
      taskTitle: map['task_title'] as String,
      assignedTo: map['assigned_to'] as String?,
      occurredAt: DateTime.parse(map['occurred_at'] as String),
    );
  }
}
