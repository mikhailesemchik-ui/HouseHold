import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/features/homes/domain/household_stats.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/statistics_screen.dart';

void main() {
  const request = HouseholdStatsRequest(
    householdId: 'hh',
    period: HouseholdStatsPeriod.last30Days,
  );
  final now = DateTime.utc(2026, 8, 27, 12);

  /// [navBarHeight] wraps the screen in a stand-in for the app shell — the
  /// same `Scaffold(extendBody: true)` + bottom navigation arrangement that
  /// publishes the nav bar's measured height as `MediaQuery.padding.bottom`.
  Widget buildScreen(
    Future<HouseholdStats> Function() loadStats, {
    List<TaskRotationSuggestion> suggestions = const [],
    Future<void> Function(TaskRotationSuggestion suggestion)? applySuggestion,
    double? navBarHeight,
  }) {
    final screen = StatisticsScreen(
      householdId: 'hh',
      applySuggestionOverride: applySuggestion,
    );
    return ProviderScope(
      overrides: [
        householdStatsProvider(request).overrideWith((ref) => loadStats()),
        taskRotationSuggestionsProvider(
          'hh',
        ).overrideWith((ref) async => suggestions),
      ],
      child: MaterialApp(
        home: navBarHeight == null
            ? screen
            : Scaffold(
                extendBody: true,
                bottomNavigationBar: SizedBox(height: navBarHeight),
                body: screen,
              ),
      ),
    );
  }

  TaskCompletionRecord completion({
    required String id,
    required String memberKey,
    required String displayName,
    required String taskTitle,
  }) {
    return TaskCompletionRecord(
      id: id,
      memberKey: memberKey,
      displayName: displayName,
      taskTitle: taskTitle,
      completedAt: now,
      isActiveMember: true,
    );
  }

  TaskRotationSuggestion suggestion() {
    return const TaskRotationSuggestion(
      taskId: 'task-1',
      taskTitle: 'Clean kitchen',
      dominantMemberId: 'u1',
      dominantMemberName: 'Anna',
      suggestedMemberId: 'u2',
      suggestedMemberName: 'Mihails',
      dominantCompletionCount: 7,
      totalCompletionCount: 8,
      dominantShare: 87.5,
    );
  }

  testWidgets('shows skeleton loading state while statistics load', (
    tester,
  ) async {
    final completer = Completer<HouseholdStats>();
    await tester.pumpWidget(buildScreen(() => completer.future));
    await tester.pump();

    expect(find.byType(AppSkeletonList), findsOneWidget);
  });

  testWidgets('shows empty state when there are no completions', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(buildScreen(() async => stats));
    await tester.pump();

    expect(find.text('Completed tasks'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('No completed tasks in this period.'), findsOneWidget);
    expect(find.text('No recurring task distribution yet.'), findsOneWidget);
  });

  testWidgets('shows member and task distribution in success state', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: [
        completion(
          id: '1',
          memberKey: 'u1',
          displayName: 'Anna',
          taskTitle: 'Clean kitchen',
        ),
        completion(
          id: '2',
          memberKey: 'u1',
          displayName: 'Anna',
          taskTitle: 'Clean kitchen',
        ),
        completion(
          id: '3',
          memberKey: 'u2',
          displayName: 'Mihails',
          taskTitle: 'Clean kitchen',
        ),
      ],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(buildScreen(() async => stats));
    await tester.pump();

    expect(find.text('Statistics'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('2 tasks - 67%'), findsOneWidget);
    expect(find.text('Mihails'), findsOneWidget);
    expect(find.text('1 task - 33%'), findsOneWidget);
    expect(find.text('Clean kitchen'), findsOneWidget);
    expect(find.text('Anna 2 - Mihails 1'), findsOneWidget);
  });

  testWidgets('shows rotation suggestion when available', (tester) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(
      buildScreen(() async => stats, suggestions: [suggestion()]),
    );
    await tester.pump();

    expect(find.text('Rotation suggestions'), findsOneWidget);
    expect(find.text('Clean kitchen'), findsOneWidget);
    expect(
      find.text('Anna completed 7 of the last 8 "Clean kitchen" tasks.'),
      findsOneWidget,
    );
    expect(
      find.text('Consider assigning the next rotation to Mihails.'),
      findsOneWidget,
    );
    expect(find.text('Apply suggestion'), findsOneWidget);
    expect(find.text('Keep current'), findsOneWidget);
  });

  testWidgets('Keep current hides suggestion for current session', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(
      buildScreen(() async => stats, suggestions: [suggestion()]),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep current'));
    await tester.pump();

    expect(find.text('Rotation suggestions'), findsNothing);
    expect(find.text('Clean kitchen'), findsNothing);
  });

  testWidgets('Apply suggestion shows loading and then success', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    final completer = Completer<void>();
    await tester.pumpWidget(
      buildScreen(
        () async => stats,
        suggestions: [suggestion()],
        applySuggestion: (_) => completer.future,
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply suggestion'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.text('Rotation suggestion applied.'), findsOneWidget);
    expect(find.text('Rotation suggestions'), findsNothing);
  });

  testWidgets('Apply suggestion shows error when apply fails', (tester) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(
      buildScreen(
        () async => stats,
        suggestions: [suggestion()],
        applySuggestion: (_) => Future.error(StateError('changed')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply suggestion'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not apply suggestion. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Rotation suggestions'), findsOneWidget);
  });

  testWidgets(
    'period selector shows all three labels without wrapping at normal '
    'text scale (regression: "30 days" used to wrap to two lines)',
    (tester) async {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.last30Days,
        completions: const [],
        now: now,
        activeMemberCount: 2,
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(360, 800)),
          child: buildScreen(() async => stats),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('7 days'), findsOneWidget);
      expect(find.text('30 days'), findsOneWidget);
      expect(find.text('All time'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Each label is exactly one Text widget — confirms it isn't wrapping
      // into two separate lines of laid-out text.
      final thirtyDays = tester.widget<Text>(find.text('30 days'));
      expect(thirtyDays.maxLines, isNull);
    },
  );

  testWidgets('period selector survives 2.0x text scale', (tester) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(2.0),
        ),
        child: buildScreen(() async => stats),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    expect(find.text('All time'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a period switches the selected cell', (tester) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last7Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    // The default period is 30 days, and tapping "7 days" re-keys the stats
    // provider request — both periods need a stats override so the switch
    // doesn't hit the real (unmockable) repository and error out.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          householdStatsProvider(request).overrideWith((ref) async => stats),
          householdStatsProvider(
            const HouseholdStatsRequest(
              householdId: 'hh',
              period: HouseholdStatsPeriod.last7Days,
            ),
          ).overrideWith((ref) async => stats),
          taskRotationSuggestionsProvider(
            'hh',
          ).overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: StatisticsScreen(householdId: 'hh')),
      ),
    );
    await tester.pumpAndSettle();

    // Starts on the default period (30 days).
    Color? colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(colorOf('30 days'), isNot(colorOf('7 days')));

    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();

    // Selection swapped: "7 days" now carries the selected-cell colour that
    // "30 days" had before, and vice versa.
    expect(colorOf('7 days'), isNot(colorOf('30 days')));
  });

  testWidgets(
    'a suggestion-provider error is distinct from "no suggestions" — it '
    'shows a recoverable message, not silence',
    (tester) async {
      final stats = HouseholdStats.fromCompletions(
        period: HouseholdStatsPeriod.last30Days,
        completions: const [],
        now: now,
        activeMemberCount: 2,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdStatsProvider(request).overrideWith((ref) async => stats),
            taskRotationSuggestionsProvider(
              'hh',
            ).overrideWith((ref) async => throw Exception('boom')),
          ],
          child: const MaterialApp(home: StatisticsScreen(householdId: 'hh')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load rotation suggestions.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    },
  );

  testWidgets('genuinely no suggestions renders no rotation section at all', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(buildScreen(() async => stats));
    await tester.pumpAndSettle();

    expect(find.text('Rotation suggestions'), findsNothing);
    expect(find.text('Could not load rotation suggestions.'), findsNothing);
  });

  testWidgets('rotation actions wrap cleanly at 2.0x text scale', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: const [],
      now: now,
      activeMemberCount: 2,
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(2.0),
        ),
        child: buildScreen(() async => stats, suggestions: [suggestion()]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Apply suggestion'), 300);

    expect(find.text('Apply suggestion'), findsOneWidget);
    expect(find.text('Keep current'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long member names do not overflow the distribution bars', (
    tester,
  ) async {
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: [
        completion(
          id: '1',
          memberKey: 'u1',
          displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
          taskTitle: 'Clean kitchen',
        ),
      ],
      now: now,
      activeMemberCount: 1,
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(360, 800)),
        child: buildScreen(() async => stats),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('list clears the shell navigation exactly once', (tester) async {
    const navBarHeight = 64.0;
    final stats = HouseholdStats.fromCompletions(
      period: HouseholdStatsPeriod.last30Days,
      completions: [
        completion(
          id: 'c1',
          memberKey: 'u1',
          displayName: 'Anna',
          taskTitle: 'Clean kitchen',
        ),
      ],
      now: now,
      activeMemberCount: 2,
    );

    double bottomPadding() {
      // The nav clearance now lives on the content `Padding` below the
      // (unpadded, so it aligns with every other screen's header) header,
      // not on the outer `ListView` itself — see Non-Sticky Headers.
      final padding = tester.widget<Padding>(
        find.byKey(const ValueKey('statisticsContentPadding')),
      );
      return (padding.padding as EdgeInsets).bottom;
    }

    await tester.pumpWidget(buildScreen(() async => stats));
    await tester.pumpAndSettle();
    final withoutShell = bottomPadding();

    await tester.pumpWidget(
      buildScreen(() async => stats, navBarHeight: navBarHeight),
    );
    await tester.pumpAndSettle();
    final withShell = bottomPadding();

    // Regression guard for the original defect: this screen passed a `const`
    // padding, which both opted out of automatic MediaQuery consumption and
    // made it impossible to include the nav clearance at all, leaving the last
    // section under the glass nav bar.
    expect(withShell - withoutShell, navBarHeight);
    expect(withShell, greaterThan(navBarHeight));
  });
}
