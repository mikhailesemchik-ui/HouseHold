import 'package:flutter/foundation.dart';

const fairnessMinimumCompletions = 10;
const fairnessConcentratedShareThreshold = 70;

@immutable
class HouseholdStatsRequest {
  const HouseholdStatsRequest({
    required this.householdId,
    required this.period,
  });

  final String householdId;
  final HouseholdStatsPeriod period;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HouseholdStatsRequest &&
          other.householdId == householdId &&
          other.period == period;

  @override
  int get hashCode => Object.hash(householdId, period);
}

enum HouseholdStatsPeriod {
  last7Days('7 days', Duration(days: 7)),
  last30Days('30 days', Duration(days: 30)),
  allTime('All time', null);

  const HouseholdStatsPeriod(this.label, this.duration);

  final String label;
  final Duration? duration;

  DateTime? startAt(DateTime now) =>
      duration == null ? null : now.subtract(duration!);
}

@immutable
class TaskCompletionRecord {
  const TaskCompletionRecord({
    required this.id,
    required this.memberKey,
    required this.displayName,
    required this.taskTitle,
    required this.completedAt,
    required this.isActiveMember,
  });

  final String id;
  final String memberKey;
  final String displayName;
  final String taskTitle;
  final DateTime completedAt;
  final bool isActiveMember;
}

@immutable
class HouseholdStats {
  const HouseholdStats({
    required this.period,
    required this.totalCompletedTasks,
    required this.memberStats,
    required this.taskDistributions,
    required this.fairnessInsight,
  });

  final HouseholdStatsPeriod period;
  final int totalCompletedTasks;
  final List<MemberTaskStats> memberStats;
  final List<TaskDistribution> taskDistributions;
  final String fairnessInsight;

  static HouseholdStats fromCompletions({
    required HouseholdStatsPeriod period,
    required List<TaskCompletionRecord> completions,
    required DateTime now,
    required int activeMemberCount,
  }) {
    final filtered = filterCompletionsForPeriod(completions, period, now);
    final total = filtered.length;
    final memberStats = groupCompletionsByMember(filtered, total);
    return HouseholdStats(
      period: period,
      totalCompletedTasks: total,
      memberStats: memberStats,
      taskDistributions: groupCompletionsByTaskTitle(filtered),
      fairnessInsight: buildFairnessInsight(
        memberStats: memberStats,
        totalCompletedTasks: total,
        activeMemberCount: activeMemberCount,
      ),
    );
  }
}

@immutable
class MemberTaskStats {
  const MemberTaskStats({
    required this.memberKey,
    required this.displayName,
    required this.completedTaskCount,
    required this.sharePercent,
    required this.isActiveMember,
  });

  final String memberKey;
  final String displayName;
  final int completedTaskCount;
  final int sharePercent;
  final bool isActiveMember;
}

@immutable
class TaskDistribution {
  const TaskDistribution({required this.taskTitle, required this.memberCounts});

  final String taskTitle;
  final List<TaskDistributionMemberCount> memberCounts;

  int get totalCompletions => memberCounts.fold(0, (sum, m) => sum + m.count);
}

@immutable
class TaskDistributionMemberCount {
  const TaskDistributionMemberCount({
    required this.memberKey,
    required this.displayName,
    required this.count,
  });

  final String memberKey;
  final String displayName;
  final int count;
}

String resolveStatsMemberDisplayName({
  required bool? isActiveMember,
  required String? profileDisplayName,
}) {
  if (profileDisplayName == null || profileDisplayName.isEmpty) {
    return 'Deleted member';
  }
  if (isActiveMember == false) return 'Former member';
  return profileDisplayName;
}

List<TaskCompletionRecord> filterCompletionsForPeriod(
  List<TaskCompletionRecord> completions,
  HouseholdStatsPeriod period,
  DateTime now,
) {
  final start = period.startAt(now.toUtc());
  if (start == null) return List.unmodifiable(completions);
  return completions
      .where((c) => !c.completedAt.toUtc().isBefore(start))
      .toList();
}

int calculateSharePercent(int count, int total) {
  if (total <= 0 || count <= 0) return 0;
  return ((count * 100) / total).round();
}

List<MemberTaskStats> groupCompletionsByMember(
  List<TaskCompletionRecord> completions,
  int totalCompletedTasks,
) {
  final byMember = <String, _MemberStatsAccumulator>{};
  for (final completion in completions) {
    byMember.update(
      completion.memberKey,
      (acc) => acc.increment(),
      ifAbsent: () => _MemberStatsAccumulator(
        memberKey: completion.memberKey,
        displayName: completion.displayName,
        isActiveMember: completion.isActiveMember,
      ).increment(),
    );
  }

  final stats =
      byMember.values
          .map(
            (acc) => MemberTaskStats(
              memberKey: acc.memberKey,
              displayName: acc.displayName,
              completedTaskCount: acc.count,
              sharePercent: calculateSharePercent(
                acc.count,
                totalCompletedTasks,
              ),
              isActiveMember: acc.isActiveMember,
            ),
          )
          .toList()
        ..sort(_compareMemberStats);
  return stats;
}

List<TaskDistribution> groupCompletionsByTaskTitle(
  List<TaskCompletionRecord> completions,
) {
  final byTitle = <String, Map<String, _TaskMemberAccumulator>>{};
  for (final completion in completions) {
    final title = completion.taskTitle.trim().isEmpty
        ? '(unknown task)'
        : completion.taskTitle.trim();
    final members = byTitle.putIfAbsent(title, () => {});
    members.update(
      completion.memberKey,
      (acc) => acc.increment(),
      ifAbsent: () => _TaskMemberAccumulator(
        memberKey: completion.memberKey,
        displayName: completion.displayName,
      ).increment(),
    );
  }

  final distributions = <TaskDistribution>[];
  for (final entry in byTitle.entries) {
    final counts =
        entry.value.values
            .map(
              (acc) => TaskDistributionMemberCount(
                memberKey: acc.memberKey,
                displayName: acc.displayName,
                count: acc.count,
              ),
            )
            .toList()
          ..sort(_compareTaskMemberCounts);
    final distribution = TaskDistribution(
      taskTitle: entry.key,
      memberCounts: counts,
    );
    if (distribution.totalCompletions >= 2) distributions.add(distribution);
  }
  distributions.sort((a, b) {
    final countCompare = b.totalCompletions.compareTo(a.totalCompletions);
    if (countCompare != 0) return countCompare;
    return a.taskTitle.compareTo(b.taskTitle);
  });
  return distributions;
}

String buildFairnessInsight({
  required List<MemberTaskStats> memberStats,
  required int totalCompletedTasks,
  required int activeMemberCount,
}) {
  if (totalCompletedTasks < fairnessMinimumCompletions) {
    return 'Not enough activity yet to evaluate task distribution.';
  }
  if (activeMemberCount < 2) {
    return 'Household responsibilities are relatively balanced.';
  }
  final activeStats = memberStats.where((m) => m.isActiveMember);
  final isConcentrated = activeStats.any(
    (m) => m.sharePercent > fairnessConcentratedShareThreshold,
  );
  if (isConcentrated) {
    return 'Household responsibilities are currently concentrated on one member.';
  }
  return 'Household responsibilities are relatively balanced.';
}

int _compareMemberStats(MemberTaskStats a, MemberTaskStats b) {
  final countCompare = b.completedTaskCount.compareTo(a.completedTaskCount);
  if (countCompare != 0) return countCompare;
  return a.displayName.compareTo(b.displayName);
}

int _compareTaskMemberCounts(
  TaskDistributionMemberCount a,
  TaskDistributionMemberCount b,
) {
  final countCompare = b.count.compareTo(a.count);
  if (countCompare != 0) return countCompare;
  return a.displayName.compareTo(b.displayName);
}

class _MemberStatsAccumulator {
  _MemberStatsAccumulator({
    required this.memberKey,
    required this.displayName,
    required this.isActiveMember,
  });

  final String memberKey;
  final String displayName;
  final bool isActiveMember;
  int count = 0;

  _MemberStatsAccumulator increment() {
    count += 1;
    return this;
  }
}

class _TaskMemberAccumulator {
  _TaskMemberAccumulator({required this.memberKey, required this.displayName});

  final String memberKey;
  final String displayName;
  int count = 0;

  _TaskMemberAccumulator increment() {
    count += 1;
    return this;
  }
}
