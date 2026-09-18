import 'package:flutter/foundation.dart';

@immutable
class TaskOccurrence {
  const TaskOccurrence({
    required this.id,
    required this.taskId,
    required this.householdId,
    required this.scheduledAt,
    required this.createdAt,
    this.assignedTo,
    this.completedAt,
    this.completedBy,
  });

  final String id;
  final String taskId;
  final String householdId;
  final DateTime scheduledAt;
  final DateTime createdAt;
  final String? assignedTo;
  final DateTime? completedAt;
  final String? completedBy;

  bool get isCompleted => completedAt != null;

  /// True when the occurrence is past its scheduled time and not yet completed.
  bool get isOverdue =>
      !isCompleted && scheduledAt.isBefore(DateTime.now().toUtc());

  factory TaskOccurrence.fromMap(Map<String, dynamic> map) {
    return TaskOccurrence(
      id: map['id'] as String,
      taskId: map['task_id'] as String,
      householdId: map['household_id'] as String,
      scheduledAt: DateTime.parse(map['scheduled_at'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      assignedTo: map['assigned_to'] as String?,
      completedAt: map['completed_at'] == null
          ? null
          : DateTime.parse(map['completed_at'] as String),
      completedBy: map['completed_by'] as String?,
    );
  }
}
