import 'package:flutter/foundation.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';

@immutable
class Task {
  const Task({
    required this.id,
    required this.householdId,
    required this.title,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.assignedTo,
    this.completedAt,
    this.completedBy,
    this.dueAt,
    this.recurrenceType = RecurrenceType.none,
  });

  final String id;
  final String householdId;
  final String title;
  final String? description;
  final String? assignedTo;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? completedBy;
  final DateTime? dueAt;
  final RecurrenceType recurrenceType;

  bool get isCompleted => completedAt != null;

  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      title: map['title'] as String,
      description: map['description'] as String?,
      assignedTo: map['assigned_to'] as String?,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      completedAt: map['completed_at'] == null
          ? null
          : DateTime.parse(map['completed_at'] as String),
      completedBy: map['completed_by'] as String?,
      dueAt: map['due_at'] == null
          ? null
          : DateTime.parse(map['due_at'] as String),
      recurrenceType: RecurrenceType.parse(
        (map['recurrence_type'] as String?) ?? 'none',
      ),
    );
  }
}
