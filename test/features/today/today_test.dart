import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';
import 'package:household_os/features/today/presentation/today_screen.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

TodayEntry makeEntry({
  String? occurrenceId = 'occ-1',
  String taskId = 'task-1',
  String title = 'Test task',
  String householdId = 'hh-1',
  String householdName = 'Home',
  DateTime? scheduledAt,
  RecurrenceType recurrenceType = RecurrenceType.none,
  TodayEntrySource sourceType = TodayEntrySource.occurrence,
}) {
  return TodayEntry(
    occurrenceId: occurrenceId,
    taskId: taskId,
    title: title,
    householdId: householdId,
    householdName: householdName,
    scheduledAt: scheduledAt,
    recurrenceType: recurrenceType,
    sourceType: sourceType,
  );
}

// Computes the UTC start of the local day containing [now].
DateTime _todayStartUtc(DateTime now) =>
    DateTime(now.year, now.month, now.day).toUtc();

DateTime _tomorrowStartUtc(DateTime now) =>
    DateTime(now.year, now.month, now.day + 1).toUtc();

// Use a fixed local "now" for all grouping tests.
final _fixedNow = DateTime(2026, 8, 27, 12, 0); // local noon
final _todayStart = _todayStartUtc(_fixedNow);
final _tomorrowStart = _tomorrowStartUtc(_fixedNow);

// ---------------------------------------------------------------------------
// groupTodayEntries — unit tests
// ---------------------------------------------------------------------------

void main() {
  group('groupTodayEntries — section placement', () {
    test('entry before local day start → overdue', () {
      final entry = makeEntry(
        scheduledAt: _todayStart.subtract(const Duration(seconds: 1)),
      );
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['overdue'], [entry]);
      expect(result['today'], isEmpty);
      expect(result['upcoming'], isEmpty);
    });

    test('entry exactly at local day start (midnight) → today', () {
      final entry = makeEntry(scheduledAt: _todayStart);
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['today'], [entry]);
      expect(result['overdue'], isEmpty);
    });

    test('entry mid-day today → today', () {
      final entry = makeEntry(
        scheduledAt: _todayStart.add(const Duration(hours: 10)),
      );
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['today'], [entry]);
    });

    test('entry exactly at tomorrow start → upcoming', () {
      final entry = makeEntry(scheduledAt: _tomorrowStart);
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['upcoming'], [entry]);
      expect(result['today'], isEmpty);
    });

    test('entry far in the future → upcoming', () {
      final entry = makeEntry(
        scheduledAt: _tomorrowStart.add(const Duration(days: 5)),
      );
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['upcoming'], [entry]);
    });

    test('null scheduledAt → anytime', () {
      final entry = makeEntry(
        scheduledAt: null,
        sourceType: TodayEntrySource.anytime,
        occurrenceId: null,
      );
      final result = groupTodayEntries([entry], _fixedNow);
      expect(result['anytime'], [entry]);
      expect(result['overdue'], isEmpty);
      expect(result['today'], isEmpty);
      expect(result['upcoming'], isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('groupTodayEntries — sorting', () {
    test('overdue entries sorted ascending by scheduledAt', () {
      final earlier = makeEntry(
        taskId: 'earlier',
        scheduledAt: _todayStart.subtract(const Duration(hours: 48)),
      );
      final later = makeEntry(
        taskId: 'later',
        scheduledAt: _todayStart.subtract(const Duration(hours: 1)),
      );
      final result = groupTodayEntries([later, earlier], _fixedNow);
      expect(result['overdue']!.map((e) => e.taskId), ['earlier', 'later']);
    });

    test('today entries sorted ascending by scheduledAt', () {
      final late_ = makeEntry(
        taskId: 'late',
        scheduledAt: _todayStart.add(const Duration(hours: 11)),
      );
      final early = makeEntry(
        taskId: 'early',
        scheduledAt: _todayStart.add(const Duration(hours: 9)),
      );
      final result = groupTodayEntries([late_, early], _fixedNow);
      expect(result['today']!.map((e) => e.taskId), ['early', 'late']);
    });

    test('upcoming entries sorted ascending by scheduledAt', () {
      final day3 = makeEntry(
        taskId: 'day3',
        scheduledAt: _tomorrowStart.add(const Duration(days: 2)),
      );
      final day1 = makeEntry(taskId: 'day1', scheduledAt: _tomorrowStart);
      final result = groupTodayEntries([day3, day1], _fixedNow);
      expect(result['upcoming']!.map((e) => e.taskId), ['day1', 'day3']);
    });
  });

  // -------------------------------------------------------------------------
  group('groupTodayEntries — upcoming limit', () {
    test('upcoming capped at 10 entries', () {
      final entries = List.generate(
        15,
        (i) => makeEntry(
          taskId: 'task-$i',
          scheduledAt: _tomorrowStart.add(Duration(days: i)),
        ),
      );
      final result = groupTodayEntries(entries, _fixedNow);
      expect(result['upcoming']!.length, 10);
    });

    test('fewer than 10 upcoming → all returned', () {
      final entries = List.generate(
        3,
        (i) => makeEntry(
          taskId: 'task-$i',
          scheduledAt: _tomorrowStart.add(Duration(days: i)),
        ),
      );
      final result = groupTodayEntries(entries, _fixedNow);
      expect(result['upcoming']!.length, 3);
    });
  });

  // -------------------------------------------------------------------------
  group('groupTodayEntries — multiple households and anytime', () {
    test('entries from two households each appear in today section', () {
      final home1 = makeEntry(
        taskId: 't1',
        householdId: 'hh-1',
        householdName: 'Home 1',
        scheduledAt: _todayStart.add(const Duration(hours: 9)),
      );
      final home2 = makeEntry(
        taskId: 't2',
        householdId: 'hh-2',
        householdName: 'Home 2',
        scheduledAt: _todayStart.add(const Duration(hours: 10)),
      );
      final result = groupTodayEntries([home1, home2], _fixedNow);
      expect(result['today']!.length, 2);
      expect(
        result['today']!.map((e) => e.householdId),
        containsAll(['hh-1', 'hh-2']),
      );
    });

    test('mix of occurrence and anytime entries are placed correctly', () {
      final occ = makeEntry(
        taskId: 'occ',
        scheduledAt: _todayStart.add(const Duration(hours: 8)),
      );
      final anytime = makeEntry(
        taskId: 'any',
        scheduledAt: null,
        sourceType: TodayEntrySource.anytime,
        occurrenceId: null,
      );
      final result = groupTodayEntries([occ, anytime], _fixedNow);
      expect(result['today']!.length, 1);
      expect(result['anytime']!.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  group('groupTodayEntries — empty inputs', () {
    test('empty list → all sections empty', () {
      final result = groupTodayEntries([], _fixedNow);
      expect(
        result.keys,
        containsAll(['overdue', 'today', 'upcoming', 'anytime']),
      );
      expect(result.values.every((l) => l.isEmpty), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('buildTodayEntries — raw row handling', () {
    Map<String, dynamic> occRow({
      required String id,
      required String taskId,
      required String householdId,
      required DateTime scheduledAt,
      String? completedAt,
    }) => {
      'id': id,
      'task_id': taskId,
      'household_id': householdId,
      'scheduled_at': scheduledAt.toIso8601String(),
      'completed_at': completedAt,
    };

    Map<String, dynamic> taskRow({
      required String id,
      required String householdId,
      required String title,
      String? dueAt,
      String? completedAt,
      String recurrenceType = 'none',
    }) => {
      'id': id,
      'household_id': householdId,
      'title': title,
      'due_at': dueAt,
      'completed_at': completedAt,
      'recurrence_type': recurrenceType,
    };

    test('incomplete occurrence is active, not completed-today', () {
      final result = buildTodayEntries(
        occRows: [
          occRow(
            id: 'o1',
            taskId: 't1',
            householdId: 'hh',
            scheduledAt: _todayStart,
          ),
        ],
        taskRows: [
          taskRow(
            id: 't1',
            householdId: 'hh',
            title: 'Task',
            dueAt: _todayStart.toIso8601String(),
          ),
        ],
        householdNames: {'hh': 'Home'},
        now: _fixedNow,
      );
      expect(result.active.length, 1);
      expect(result.completedToday, isEmpty);
    });

    test('occurrence completed today moves to completed-today', () {
      final completedAt = _todayStart.add(const Duration(hours: 1));
      final result = buildTodayEntries(
        occRows: [
          occRow(
            id: 'o1',
            taskId: 't1',
            householdId: 'hh',
            scheduledAt: _todayStart,
            completedAt: completedAt.toIso8601String(),
          ),
        ],
        taskRows: [
          taskRow(
            id: 't1',
            householdId: 'hh',
            title: 'Task',
            dueAt: _todayStart.toIso8601String(),
          ),
        ],
        householdNames: {'hh': 'Home'},
        now: _fixedNow,
      );
      expect(result.active, isEmpty);
      expect(result.completedToday.length, 1);
    });

    test('occurrence completed on a previous day is excluded entirely', () {
      final completedYesterday = _todayStart.subtract(const Duration(hours: 2));
      final result = buildTodayEntries(
        occRows: [
          occRow(
            id: 'o1',
            taskId: 't1',
            householdId: 'hh',
            scheduledAt: _todayStart,
            completedAt: completedYesterday.toIso8601String(),
          ),
        ],
        taskRows: [
          taskRow(
            id: 't1',
            householdId: 'hh',
            title: 'Task',
            dueAt: _todayStart.toIso8601String(),
          ),
        ],
        householdNames: {'hh': 'Home'},
        now: _fixedNow,
      );
      expect(result.active, isEmpty);
      expect(result.completedToday, isEmpty);
    });

    test('anytime task completed today appears in completed-today', () {
      final completedAt = _todayStart.add(const Duration(hours: 2));
      final result = buildTodayEntries(
        occRows: const [],
        taskRows: [
          taskRow(
            id: 't2',
            householdId: 'hh',
            title: 'Anytime task',
            completedAt: completedAt.toIso8601String(),
          ),
        ],
        householdNames: {'hh': 'Home'},
        now: _fixedNow,
      );
      expect(result.completedToday.length, 1);
      expect(result.completedToday.single.sourceType, TodayEntrySource.anytime);
    });

    test('a dated task row is not treated as an anytime task', () {
      final result = buildTodayEntries(
        occRows: const [],
        taskRows: [
          taskRow(
            id: 't3',
            householdId: 'hh',
            title: 'Dated',
            dueAt: _todayStart.toIso8601String(),
          ),
        ],
        householdNames: {'hh': 'Home'},
        now: _fixedNow,
      );
      expect(result.active, isEmpty);
      expect(result.completedToday, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('TodayScreen — widget tests', () {
    /// [navBarHeight] wraps the screen in a stand-in for the app shell — the
    /// same `Scaffold(extendBody: true)` + bottom navigation arrangement that
    /// publishes the nav bar's measured height as `MediaQuery.padding.bottom`.
    Widget buildScreen(
      Map<String, List<TodayEntry>> sections, {
      double? navBarHeight,
    }) {
      const screen = TodayScreen();
      return ProviderScope(
        overrides: [
          todayProvider.overrideWith(() => _FakeTodayNotifier(sections)),
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

    testWidgets('shows empty state when all sections are empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();
      expect(find.text('Nothing assigned to you.'), findsOneWidget);
    });

    testWidgets('shows overdue section header and entry title', (tester) async {
      final entry = makeEntry(
        title: 'Fix the leak',
        scheduledAt: _todayStart.subtract(const Duration(hours: 2)),
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [entry],
          'today': [],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.text('Fix the leak'), findsOneWidget);
    });

    testWidgets('shows anytime section without time text', (tester) async {
      final entry = makeEntry(
        title: 'Buy groceries',
        scheduledAt: null,
        sourceType: TodayEntrySource.anytime,
        occurrenceId: null,
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [],
          'upcoming': [],
          'anytime': [entry],
        }),
      );
      await tester.pump();
      // Section header "Anytime" + tile time label "Anytime" = 2 matches.
      expect(find.text('Anytime'), findsNWidgets(2));
      expect(find.text('Buy groceries'), findsOneWidget);
    });

    testWidgets('repeat icon shown for recurring entry', (tester) async {
      final entry = makeEntry(
        title: 'Water plants',
        scheduledAt: _todayStart.add(const Duration(hours: 8)),
        recurrenceType: RecurrenceType.daily,
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [entry],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      // The glyph alone isn't accessible meaning — it needs a real label.
      expect(find.bySemanticsLabel('Repeats daily'), findsOneWidget);
    });

    testWidgets('hides section header when section is empty', (tester) async {
      final entry = makeEntry(
        title: 'Daily standup',
        scheduledAt: _todayStart.add(const Duration(hours: 9)),
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [entry],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();
      // AppBar title is also "Today"; verify only empty section headers are absent.
      expect(find.text('Daily standup'), findsOneWidget);
      expect(find.text('Overdue'), findsNothing);
      expect(find.text('Upcoming'), findsNothing);
      expect(find.text('Anytime'), findsNothing);
    });

    testWidgets('long task title and household name wrap without overflow', (
      tester,
    ) async {
      final entry = makeEntry(
        title:
            'Deep clean the entire upstairs bathroom including the grout '
            'and the extractor fan',
        scheduledAt: _todayStart.add(const Duration(hours: 9)),
        householdName:
            'The Extended Family Household With A Very Long Descriptive Name',
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [entry],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();

      expect(find.textContaining('Deep clean the entire'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('completion control announces as an action, not a checkbox', (
      tester,
    ) async {
      final entry = makeEntry(
        title: 'Water plants',
        scheduledAt: _todayStart.add(const Duration(hours: 8)),
      );
      await tester.pumpWidget(
        buildScreen({
          'overdue': [],
          'today': [entry],
          'upcoming': [],
          'anytime': [],
        }),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel('Mark "Water plants" as done'),
        findsOneWidget,
      );
    });

    testWidgets(
      'multiple sections with a long title render at 2.0x without overflow',
      (tester) async {
        final entries = {
          'overdue': [
            makeEntry(
              taskId: 'od',
              title: 'Fix the leak',
              scheduledAt: _todayStart.subtract(const Duration(hours: 2)),
            ),
          ],
          'today': [
            makeEntry(
              taskId: 'td',
              title:
                  'Deep clean the entire upstairs bathroom including the '
                  'grout and the extractor fan',
              scheduledAt: _todayStart.add(const Duration(hours: 9)),
              recurrenceType: RecurrenceType.weekly,
            ),
          ],
          'upcoming': [makeEntry(taskId: 'up', scheduledAt: _tomorrowStart)],
          'anytime': [
            makeEntry(
              taskId: 'any',
              scheduledAt: null,
              sourceType: TodayEntrySource.anytime,
              occurrenceId: null,
            ),
          ],
        };

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              textScaler: TextScaler.linear(2.0),
            ),
            child: buildScreen(entries),
          ),
        );
        await tester.pump();

        expect(find.text('Overdue'), findsOneWidget);
        expect(find.text('Today'), findsWidgets);
        expect(find.text('Upcoming'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('last row clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      final sections = {
        'overdue': <TodayEntry>[],
        'today': [makeEntry(title: 'Water plants')],
        'upcoming': <TodayEntry>[],
        'anytime': <TodayEntry>[],
      };

      double bottomPadding() {
        final sliverPadding = tester.widget<SliverPadding>(
          find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(SliverPadding),
              )
              .first,
        );
        return (sliverPadding.padding as EdgeInsets).bottom;
      }

      await tester.pumpWidget(buildScreen(sections));
      await tester.pump();
      final withoutShell = bottomPadding();

      await tester.pumpWidget(
        buildScreen(sections, navBarHeight: navBarHeight),
      );
      await tester.pump();
      final withShell = bottomPadding();

      // Regression guard: this screen previously counted the nav bar three
      // times — the list consumed MediaQuery.padding automatically *and* a
      // trailing spacer re-added the device inset plus a nav-height constant.
      expect(withShell - withoutShell, navBarHeight);
      expect(withShell, navBarHeight);
    });
  });
}

// Fake notifier for widget tests — avoids real Supabase dependency.
class _FakeTodayNotifier extends TodayNotifier {
  _FakeTodayNotifier(this._sections);
  final Map<String, List<TodayEntry>> _sections;

  @override
  Future<Map<String, List<TodayEntry>>> build() async => _sections;
}
