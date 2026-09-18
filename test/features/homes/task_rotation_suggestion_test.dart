import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 12);

  RotationTaskSnapshot task({
    String id = 'task-1',
    String title = 'Clean kitchen',
    RecurrenceType recurrenceType = RecurrenceType.weekly,
    String? assignedTo,
  }) {
    return RotationTaskSnapshot(
      id: id,
      title: title,
      recurrenceType: recurrenceType,
      assignedTo: assignedTo,
    );
  }

  RotationMemberSnapshot member({
    required String id,
    required String name,
    String publicId = '',
    bool isActive = true,
  }) {
    return RotationMemberSnapshot(
      userId: id,
      displayName: name,
      publicId: publicId,
      isActive: isActive,
    );
  }

  RotationCompletionRecord completion({
    required String id,
    String taskId = 'task-1',
    required String? completedBy,
    DateTime? completedAt,
  }) {
    return RotationCompletionRecord(
      id: id,
      taskId: taskId,
      completedBy: completedBy,
      completedAt: completedAt ?? now,
    );
  }

  List<TaskRotationSuggestion> suggestions({
    List<RotationTaskSnapshot>? tasks,
    List<RotationMemberSnapshot>? members,
    required List<RotationCompletionRecord> completions,
    Map<String, int> overallCounts = const {},
  }) {
    return buildTaskRotationSuggestions(
      tasks: tasks ?? [task()],
      members:
          members ??
          [
            member(id: 'u1', name: 'Anna', publicId: 'anna#1'),
            member(id: 'u2', name: 'Mihails', publicId: 'mihails#1'),
          ],
      completions: completions,
      overallCompletionCounts: overallCounts,
      now: now,
    );
  }

  group('buildTaskRotationSuggestions', () {
    test('below minimum history returns no suggestion', () {
      final result = suggestions(
        completions: List.generate(
          3,
          (i) => completion(id: '$i', completedBy: 'u1'),
        ),
      );

      expect(result, isEmpty);
    });

    test('exactly minimum history can qualify', () {
      final result = suggestions(
        completions: [
          completion(id: '1', completedBy: 'u1'),
          completion(id: '2', completedBy: 'u1'),
          completion(id: '3', completedBy: 'u1'),
          completion(id: '4', completedBy: 'u1'),
        ],
      );

      expect(result, hasLength(1));
      expect(result.single.dominantCompletionCount, 4);
      expect(result.single.totalCompletionCount, 4);
    });

    test(
      '75 percent does not qualify because threshold is strictly greater',
      () {
        final result = suggestions(
          completions: [
            completion(id: '1', completedBy: 'u1'),
            completion(id: '2', completedBy: 'u1'),
            completion(id: '3', completedBy: 'u1'),
            completion(id: '4', completedBy: 'u2'),
          ],
        );

        expect(result, isEmpty);
      },
    );

    test('more than 75 percent qualifies', () {
      final result = suggestions(
        completions: [
          completion(id: '1', completedBy: 'u1'),
          completion(id: '2', completedBy: 'u1'),
          completion(id: '3', completedBy: 'u1'),
          completion(id: '4', completedBy: 'u1'),
          completion(id: '5', completedBy: 'u2'),
        ],
      );

      expect(result, hasLength(1));
      expect(result.single.dominantMemberId, 'u1');
      expect(result.single.dominantMemberName, 'Anna');
      expect(result.single.suggestedMemberId, 'u2');
      expect(result.single.dominantShare, 80);
    });

    test('balanced task returns no suggestion', () {
      final result = suggestions(
        completions: [
          completion(id: '1', completedBy: 'u1'),
          completion(id: '2', completedBy: 'u1'),
          completion(id: '3', completedBy: 'u2'),
          completion(id: '4', completedBy: 'u2'),
        ],
      );

      expect(result, isEmpty);
    });

    test('target member is active member with fewest task completions', () {
      final result = suggestions(
        members: [
          member(id: 'u1', name: 'Anna'),
          member(id: 'u2', name: 'Mihails'),
          member(id: 'u3', name: 'Zoey'),
        ],
        completions: [
          ...List.generate(7, (i) => completion(id: 'a$i', completedBy: 'u1')),
          completion(id: 'b1', completedBy: 'u2'),
          completion(id: 'b2', completedBy: 'u2'),
        ],
      );

      expect(result.single.suggestedMemberId, 'u3');
    });

    test('overall completion count breaks target ties', () {
      final result = suggestions(
        members: [
          member(id: 'u1', name: 'Anna'),
          member(id: 'u2', name: 'Mihails'),
          member(id: 'u3', name: 'Zoey'),
        ],
        completions: List.generate(
          4,
          (i) => completion(id: 'a$i', completedBy: 'u1'),
        ),
        overallCounts: {'u2': 5, 'u3': 1},
      );

      expect(result.single.suggestedMemberId, 'u3');
    });

    test(
      'display name and public id provide deterministic final tie-break',
      () {
        final result = suggestions(
          members: [
            member(id: 'u1', name: 'Zara'),
            member(id: 'u2', name: 'Mihails', publicId: 'm#2'),
            member(id: 'u3', name: 'Anna', publicId: 'a#1'),
          ],
          completions: List.generate(
            4,
            (i) => completion(id: 'a$i', completedBy: 'u1'),
          ),
        );

        expect(result.single.suggestedMemberId, 'u3');
      },
    );

    test('former members are excluded as rotation targets', () {
      final result = suggestions(
        members: [
          member(id: 'u1', name: 'Anna'),
          member(id: 'u2', name: 'Former member', isActive: false),
          member(id: 'u3', name: 'Mihails'),
        ],
        completions: [
          ...List.generate(7, (i) => completion(id: 'a$i', completedBy: 'u1')),
          completion(id: 'f1', completedBy: 'u2'),
        ],
      );

      expect(result.single.suggestedMemberId, 'u3');
    });

    test('only one active member returns no suggestion', () {
      final result = suggestions(
        members: [
          member(id: 'u1', name: 'Anna'),
          member(id: 'u2', name: 'Former member', isActive: false),
        ],
        completions: List.generate(
          4,
          (i) => completion(id: '$i', completedBy: 'u1'),
        ),
      );

      expect(result, isEmpty);
    });

    test('no recurring tasks returns no suggestion', () {
      final result = suggestions(
        tasks: [task(recurrenceType: RecurrenceType.none)],
        completions: List.generate(
          4,
          (i) => completion(id: '$i', completedBy: 'u1'),
        ),
      );

      expect(result, isEmpty);
    });

    test('old completions outside 60 days are ignored', () {
      final result = suggestions(
        completions: [
          ...List.generate(3, (i) => completion(id: 'r$i', completedBy: 'u1')),
          completion(
            id: 'old',
            completedBy: 'u1',
            completedAt: now.subtract(const Duration(days: 61)),
          ),
        ],
      );

      expect(result, isEmpty);
    });

    test(
      'suggestion contains only task template assignment data for apply',
      () {
        final result = suggestions(
          tasks: [task(assignedTo: null)],
          completions: List.generate(
            4,
            (i) => completion(id: '$i', completedBy: 'u1'),
          ),
        );

        expect(result.single.taskId, 'task-1');
        expect(result.single.currentAssigneeId, isNull);
        expect(result.single.suggestedMemberId, 'u2');
      },
    );
  });
}
