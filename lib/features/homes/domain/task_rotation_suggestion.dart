import 'package:flutter/foundation.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';

const rotationAnalysisWindow = Duration(days: 60);
const rotationMinimumTaskCompletions = 4;
const rotationConcentratedShareThreshold = 75.0;

@immutable
class TaskRotationSuggestion {
  const TaskRotationSuggestion({
    required this.taskId,
    required this.taskTitle,
    required this.dominantMemberId,
    required this.dominantMemberName,
    required this.suggestedMemberId,
    required this.suggestedMemberName,
    required this.dominantCompletionCount,
    required this.totalCompletionCount,
    required this.dominantShare,
    this.currentAssigneeId,
  });

  final String taskId;
  final String taskTitle;
  final String? currentAssigneeId;
  final String dominantMemberId;
  final String dominantMemberName;
  final String suggestedMemberId;
  final String suggestedMemberName;
  final int dominantCompletionCount;
  final int totalCompletionCount;
  final double dominantShare;

  String get reasonText =>
      '$dominantMemberName completed $dominantCompletionCount of the last '
      '$totalCompletionCount "$taskTitle" tasks.';

  String get suggestionText =>
      'Consider assigning the next rotation to $suggestedMemberName.';
}

@immutable
class RotationTaskSnapshot {
  const RotationTaskSnapshot({
    required this.id,
    required this.title,
    required this.recurrenceType,
    this.assignedTo,
  });

  final String id;
  final String title;
  final RecurrenceType recurrenceType;
  final String? assignedTo;

  bool get isRecurring =>
      recurrenceType == RecurrenceType.daily ||
      recurrenceType == RecurrenceType.weekly;
}

@immutable
class RotationMemberSnapshot {
  const RotationMemberSnapshot({
    required this.userId,
    required this.displayName,
    required this.publicId,
    required this.isActive,
  });

  final String userId;
  final String displayName;
  final String publicId;
  final bool isActive;
}

@immutable
class RotationCompletionRecord {
  const RotationCompletionRecord({
    required this.id,
    required this.taskId,
    required this.completedBy,
    required this.completedAt,
  });

  final String id;
  final String taskId;
  final String? completedBy;
  final DateTime completedAt;
}

List<TaskRotationSuggestion> buildTaskRotationSuggestions({
  required List<RotationTaskSnapshot> tasks,
  required List<RotationMemberSnapshot> members,
  required List<RotationCompletionRecord> completions,
  required Map<String, int> overallCompletionCounts,
  required DateTime now,
}) {
  final activeMembers = members.where((m) => m.isActive).toList()
    ..sort(_compareMembersStable);
  if (activeMembers.length < 2) return const [];

  final start = now.toUtc().subtract(rotationAnalysisWindow);
  final recurringTasks = {
    for (final task in tasks.where((t) => t.isRecurring)) task.id: task,
  };
  if (recurringTasks.isEmpty) return const [];

  final completionsByTask = <String, List<RotationCompletionRecord>>{};
  for (final completion in completions) {
    if (!recurringTasks.containsKey(completion.taskId)) continue;
    if (completion.completedBy == null) continue;
    if (completion.completedAt.toUtc().isBefore(start)) continue;
    completionsByTask.putIfAbsent(completion.taskId, () => []).add(completion);
  }

  final suggestions = <TaskRotationSuggestion>[];
  final activeMemberIds = activeMembers.map((m) => m.userId).toSet();
  final memberById = {for (final member in members) member.userId: member};

  for (final entry in completionsByTask.entries) {
    final taskCompletions = entry.value;
    if (taskCompletions.length < rotationMinimumTaskCompletions) continue;

    final taskCounts = <String, int>{};
    for (final completion in taskCompletions) {
      final memberId = completion.completedBy!;
      taskCounts.update(memberId, (count) => count + 1, ifAbsent: () => 1);
    }

    final activeCounts =
        taskCounts.entries
            .where((entry) => activeMemberIds.contains(entry.key))
            .toList()
          ..sort((a, b) {
            final countCompare = b.value.compareTo(a.value);
            if (countCompare != 0) return countCompare;
            return _compareMembersStable(
              memberById[a.key]!,
              memberById[b.key]!,
            );
          });
    if (activeCounts.isEmpty) continue;

    final dominant = activeCounts.first;
    final dominantShare = dominant.value * 100 / taskCompletions.length;
    if (dominantShare <= rotationConcentratedShareThreshold) continue;

    final candidates =
        activeMembers.where((member) => member.userId != dominant.key).toList()
          ..sort(
            (a, b) => _compareRotationCandidates(
              a,
              b,
              taskCounts,
              overallCompletionCounts,
            ),
          );
    if (candidates.isEmpty) continue;

    final task = recurringTasks[entry.key]!;
    final dominantMember = memberById[dominant.key];
    if (dominantMember == null || !dominantMember.isActive) continue;
    final suggested = candidates.first;

    suggestions.add(
      TaskRotationSuggestion(
        taskId: task.id,
        taskTitle: task.title,
        currentAssigneeId: task.assignedTo,
        dominantMemberId: dominant.key,
        dominantMemberName: dominantMember.displayName,
        suggestedMemberId: suggested.userId,
        suggestedMemberName: suggested.displayName,
        dominantCompletionCount: dominant.value,
        totalCompletionCount: taskCompletions.length,
        dominantShare: dominantShare,
      ),
    );
  }

  suggestions.sort((a, b) {
    final shareCompare = b.dominantShare.compareTo(a.dominantShare);
    if (shareCompare != 0) return shareCompare;
    return a.taskTitle.compareTo(b.taskTitle);
  });
  return suggestions;
}

int _compareRotationCandidates(
  RotationMemberSnapshot a,
  RotationMemberSnapshot b,
  Map<String, int> taskCounts,
  Map<String, int> overallCompletionCounts,
) {
  final taskCompare = (taskCounts[a.userId] ?? 0).compareTo(
    taskCounts[b.userId] ?? 0,
  );
  if (taskCompare != 0) return taskCompare;
  final overallCompare = (overallCompletionCounts[a.userId] ?? 0).compareTo(
    overallCompletionCounts[b.userId] ?? 0,
  );
  if (overallCompare != 0) return overallCompare;
  return _compareMembersStable(a, b);
}

int _compareMembersStable(RotationMemberSnapshot a, RotationMemberSnapshot b) {
  final nameCompare = a.displayName.compareTo(b.displayName);
  if (nameCompare != 0) return nameCompare;
  final publicIdCompare = a.publicId.compareTo(b.publicId);
  if (publicIdCompare != 0) return publicIdCompare;
  return a.userId.compareTo(b.userId);
}
