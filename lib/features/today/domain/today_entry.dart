import 'package:flutter/foundation.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';

enum TodayEntrySource { occurrence, anytime }

@immutable
class TodayEntry {
  const TodayEntry({
    required this.occurrenceId,
    required this.taskId,
    required this.title,
    required this.householdId,
    required this.householdName,
    required this.scheduledAt,
    required this.recurrenceType,
    required this.sourceType,
  });

  final String? occurrenceId;
  final String taskId;
  final String title;
  final String householdId;
  final String householdName;
  final DateTime? scheduledAt;
  final RecurrenceType recurrenceType;
  final TodayEntrySource sourceType;

  /// True when the entry's scheduled time is before the current local day start.
  bool get isOverdue {
    if (scheduledAt == null) return false;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toUtc();
    return scheduledAt!.isBefore(todayStart);
  }
}
