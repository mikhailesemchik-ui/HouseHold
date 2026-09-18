import 'package:flutter/foundation.dart';
import 'package:household_os/core/services/notification_service.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

@immutable
class ReminderTarget {
  const ReminderTarget({
    required this.occurrenceId,
    required this.title,
    required this.householdName,
    required this.householdId,
    required this.scheduledAt,
  });

  final String occurrenceId;
  final String title;
  final String householdName;
  final String householdId;
  final DateTime scheduledAt; // UTC
}

@immutable
class ReconciliationResult {
  const ReconciliationResult({
    required this.toSchedule,
    required this.toCancel,
  });

  final List<ReminderTarget> toSchedule;
  final List<int> toCancel;
}

class ReminderCoordinator {
  /// Derives a stable 31-bit notification ID from an occurrence UUID.
  /// FNV-1a 32-bit hash, masked to a positive signed 32-bit range.
  static int notificationId(String occurrenceId) {
    var hash = 2166136261; // FNV-32 offset basis
    for (final byte in occurrenceId.codeUnits) {
      hash ^= byte;
      hash = (hash * 16777619) & 0xFFFFFFFF; // FNV-32 prime
    }
    return hash & 0x7FFFFFFF; // keep within positive 31-bit range
  }

  /// Returns the subset of [entries] that should have reminders scheduled:
  /// future, scheduled, occurrence-backed entries assigned to the current user.
  static List<ReminderTarget> targetsFromEntries({
    required List<TodayEntry> entries,
    required DateTime now,
  }) {
    return entries
        .where(
          (e) =>
              e.sourceType == TodayEntrySource.occurrence &&
              e.occurrenceId != null &&
              e.scheduledAt != null &&
              e.scheduledAt!.isAfter(now),
        )
        .map(
          (e) => ReminderTarget(
            occurrenceId: e.occurrenceId!,
            title: e.title,
            householdName: e.householdName,
            householdId: e.householdId,
            scheduledAt: e.scheduledAt!,
          ),
        )
        .toList();
  }

  /// Diffs [targets] against [currentlyScheduledIds] to produce a list of
  /// reminders to schedule and IDs to cancel.
  static ReconciliationResult reconcile({
    required List<ReminderTarget> targets,
    required Set<int> currentlyScheduledIds,
  }) {
    final toSchedule = <ReminderTarget>[];
    final expectedIds = <int>{};

    for (final target in targets) {
      final id = notificationId(target.occurrenceId);
      expectedIds.add(id);
      if (!currentlyScheduledIds.contains(id)) {
        toSchedule.add(target);
      }
    }

    final toCancel = currentlyScheduledIds
        .where((id) => !expectedIds.contains(id))
        .toList();

    return ReconciliationResult(toSchedule: toSchedule, toCancel: toCancel);
  }

  /// Fetches pending IDs, diffs against [entries], then schedules/cancels.
  static Future<void> runReconciliation({
    required LocalNotificationService service,
    required List<TodayEntry> entries,
    required DateTime now,
  }) async {
    final pendingIds = await service.pendingNotificationIds();
    final targets = targetsFromEntries(entries: entries, now: now);
    final result = reconcile(
      targets: targets,
      currentlyScheduledIds: pendingIds.toSet(),
    );

    for (final id in result.toCancel) {
      await service.cancelReminder(id);
    }
    for (final target in result.toSchedule) {
      await service.scheduleReminder(
        id: notificationId(target.occurrenceId),
        title: 'Household OS',
        body: '${target.title} · ${target.householdName}',
        scheduledAt: target.scheduledAt,
        payload: target.householdId,
      );
    }
  }
}
