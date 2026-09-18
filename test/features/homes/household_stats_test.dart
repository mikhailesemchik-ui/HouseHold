import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/homes/domain/household_stats.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 12);

  TaskCompletionRecord completion({
    required String id,
    required String memberKey,
    required String displayName,
    required String taskTitle,
    required DateTime completedAt,
    bool isActiveMember = true,
  }) {
    return TaskCompletionRecord(
      id: id,
      memberKey: memberKey,
      displayName: displayName,
      taskTitle: taskTitle,
      completedAt: completedAt,
      isActiveMember: isActiveMember,
    );
  }

  group('HouseholdStats', () {
    test('handles zero completions without division by zero', () {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.last30Days,
        completions: const [],
        now: now,
        activeMemberCount: 2,
      );

      expect(stats.totalCompletedTasks, 0);
      expect(stats.memberStats, isEmpty);
      expect(stats.taskDistributions, isEmpty);
      expect(
        stats.fairnessInsight,
        'Not enough activity yet to evaluate task distribution.',
      );
      expect(calculateSharePercent(1, 0), 0);
    });

    test('aggregates one member and calculates 100 percent share', () {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.allTime,
        completions: [
          completion(
            id: '1',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'Clean kitchen',
            completedAt: now,
          ),
        ],
        now: now,
        activeMemberCount: 1,
      );

      expect(stats.totalCompletedTasks, 1);
      expect(stats.memberStats.single.displayName, 'Anna');
      expect(stats.memberStats.single.completedTaskCount, 1);
      expect(stats.memberStats.single.sharePercent, 100);
    });

    test(
      'aggregates multiple members and calculates deterministic percentages',
      () {
        final stats = HouseholdStats.fromCompletions(
          period: HouseholdStatsPeriod.allTime,
          completions: [
            completion(
              id: '1',
              memberKey: 'u1',
              displayName: 'Anna',
              taskTitle: 'A',
              completedAt: now,
            ),
            completion(
              id: '2',
              memberKey: 'u1',
              displayName: 'Anna',
              taskTitle: 'B',
              completedAt: now,
            ),
            completion(
              id: '3',
              memberKey: 'u2',
              displayName: 'Mihails',
              taskTitle: 'C',
              completedAt: now,
            ),
          ],
          now: now,
          activeMemberCount: 2,
        );

        expect(stats.memberStats.map((m) => m.completedTaskCount), [2, 1]);
        expect(stats.memberStats.map((m) => m.sharePercent), [67, 33]);
        expect(calculateSharePercent(1, 4), 25);
      },
    );

    test('filters last 7 days using completion timestamps', () {
      final filtered = filterCompletionsForPeriod(
        [
          completion(
            id: 'recent',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now.subtract(const Duration(days: 6)),
          ),
          completion(
            id: 'old',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now.subtract(const Duration(days: 8)),
          ),
        ],
        HouseholdStatsPeriod.last7Days,
        now,
      );

      expect(filtered.map((c) => c.id), ['recent']);
    });

    test('filters last 30 days using completion timestamps', () {
      final filtered = filterCompletionsForPeriod(
        [
          completion(
            id: 'recent',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now.subtract(const Duration(days: 29)),
          ),
          completion(
            id: 'old',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now.subtract(const Duration(days: 31)),
          ),
        ],
        HouseholdStatsPeriod.last30Days,
        now,
      );

      expect(filtered.map((c) => c.id), ['recent']);
    });

    test('all time keeps all completions', () {
      final filtered = filterCompletionsForPeriod(
        [
          completion(
            id: 'recent',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now,
          ),
          completion(
            id: 'old',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now.subtract(const Duration(days: 400)),
          ),
        ],
        HouseholdStatsPeriod.allTime,
        now,
      );

      expect(filtered.length, 2);
    });

    test('resolves former-member display without exposing identity', () {
      expect(
        resolveStatsMemberDisplayName(
          isActiveMember: false,
          profileDisplayName: 'Anna',
        ),
        'Former member',
      );
    });

    test('resolves deleted-member fallback when profile is missing', () {
      expect(
        resolveStatsMemberDisplayName(
          isActiveMember: false,
          profileDisplayName: null,
        ),
        'Deleted member',
      );
    });

    test('groups per-task distribution by task title and member', () {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.allTime,
        completions: [
          completion(
            id: '1',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'Clean kitchen',
            completedAt: now,
          ),
          completion(
            id: '2',
            memberKey: 'u2',
            displayName: 'Mihails',
            taskTitle: 'Clean kitchen',
            completedAt: now,
          ),
          completion(
            id: '3',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'Clean kitchen',
            completedAt: now,
          ),
        ],
        now: now,
        activeMemberCount: 2,
      );

      expect(stats.taskDistributions.single.taskTitle, 'Clean kitchen');
      expect(stats.taskDistributions.single.totalCompletions, 3);
      expect(
        stats.taskDistributions.single.memberCounts.first.displayName,
        'Anna',
      );
      expect(stats.taskDistributions.single.memberCounts.first.count, 2);
    });

    test('excludes tasks with fewer than 2 completions from distribution', () {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.allTime,
        completions: [
          completion(
            id: '1',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'One-off',
            completedAt: now,
          ),
          completion(
            id: '2',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'Recurring',
            completedAt: now,
          ),
          completion(
            id: '3',
            memberKey: 'u2',
            displayName: 'Mihails',
            taskTitle: 'Recurring',
            completedAt: now,
          ),
        ],
        now: now,
        activeMemberCount: 2,
      );

      expect(stats.taskDistributions.map((d) => d.taskTitle), ['Recurring']);
    });

    test('fairness insight is neutral below minimum sample', () {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.allTime,
        completions: List.generate(
          9,
          (i) => completion(
            id: '$i',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now,
          ),
        ),
        now: now,
        activeMemberCount: 2,
      );

      expect(
        stats.fairnessInsight,
        'Not enough activity yet to evaluate task distribution.',
      );
    });

    test(
      'fairness insight detects concentrated active-member share above 70 percent',
      () {
        final completions = [
          ...List.generate(
            8,
            (i) => completion(
              id: 'a$i',
              memberKey: 'u1',
              displayName: 'Anna',
              taskTitle: 'A',
              completedAt: now,
            ),
          ),
          ...List.generate(
            2,
            (i) => completion(
              id: 'b$i',
              memberKey: 'u2',
              displayName: 'Mihails',
              taskTitle: 'B',
              completedAt: now,
            ),
          ),
        ];
        final stats = HouseholdStats.fromCompletions(
          period: HouseholdStatsPeriod.allTime,
          completions: completions,
          now: now,
          activeMemberCount: 2,
        );

        expect(
          stats.fairnessInsight,
          'Household responsibilities are currently concentrated on one member.',
        );
      },
    );

    test('fairness insight reports balanced distribution otherwise', () {
      final completions = [
        ...List.generate(
          5,
          (i) => completion(
            id: 'a$i',
            memberKey: 'u1',
            displayName: 'Anna',
            taskTitle: 'A',
            completedAt: now,
          ),
        ),
        ...List.generate(
          5,
          (i) => completion(
            id: 'b$i',
            memberKey: 'u2',
            displayName: 'Mihails',
            taskTitle: 'B',
            completedAt: now,
          ),
        ),
      ];
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.allTime,
        completions: completions,
        now: now,
        activeMemberCount: 2,
      );

      expect(
        stats.fairnessInsight,
        'Household responsibilities are relatively balanced.',
      );
    });
  });
}
