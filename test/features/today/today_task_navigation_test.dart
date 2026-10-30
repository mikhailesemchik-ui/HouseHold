import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/domain/today_entry.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';
import 'package:household_os/features/today/presentation/today_screen.dart';

class _FakeTodayNotifier extends TodayNotifier {
  _FakeTodayNotifier(this._sections);
  final Map<String, List<TodayEntry>> _sections;

  @override
  Future<Map<String, List<TodayEntry>>> build() async => _sections;
}

// What a Today tap sends to the Tasks route. The Tasks screen itself is
// covered in tasks_focus_test.dart; the route here only reports what it got.
void main() {
  final soon = DateTime.now().toUtc().add(const Duration(hours: 1));

  // A recurring occurrence in household 1, a task without a date in household 2.
  final recurring = TodayEntry(
    occurrenceId: 'occ-A2',
    taskId: 'task-A',
    title: 'Water plants',
    householdId: 'hh-1',
    householdName: 'Home One',
    scheduledAt: soon,
    recurrenceType: RecurrenceType.weekly,
    sourceType: TodayEntrySource.occurrence,
  );
  const anytime = TodayEntry(
    occurrenceId: null,
    taskId: 'task-B',
    title: 'Fix shelf',
    householdId: 'hh-2',
    householdName: 'Home Two',
    scheduledAt: null,
    recurrenceType: RecurrenceType.none,
    sourceType: TodayEntrySource.anytime,
  );

  late GoRouter router;
  late List<String> tasksOpened;

  Widget app() {
    tasksOpened = [];
    router = GoRouter(
      initialLocation: '/today',
      routes: [
        GoRoute(path: '/today', builder: (_, _) => const TodayScreen()),
        GoRoute(
          path: '/homes/:householdId/tasks',
          builder: (_, state) {
            tasksOpened.add(state.uri.toString());
            final q = state.uri.queryParameters;
            return Scaffold(
              body: Text(
                'tasks ${state.pathParameters['householdId']} '
                'task=${q['task']} occurrence=${q['occurrence']}',
              ),
            );
          },
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        todayProvider.overrideWith(
          () => _FakeTodayNotifier({
            'overdue': const [],
            'today': [recurring],
            'upcoming': const [],
            'anytime': const [anytime],
          }),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('a scheduled row sends its household, parent task and its own '
      'occurrence', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Water plants'));
    await tester.pumpAndSettle();

    expect(
      find.text('tasks hh-1 task=task-A occurrence=occ-A2'),
      findsOneWidget,
    );
  });

  testWidgets('a row without a date sends only its task', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fix shelf'));
    await tester.pumpAndSettle();

    expect(find.text('tasks hh-2 task=task-B occurrence=null'), findsOneWidget);
  });

  testWidgets('the other row opens its own task after coming back to Today', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Water plants'));
    await tester.pumpAndSettle();

    router.go('/today');
    await tester.pumpAndSettle();
    expect(find.text('Water plants'), findsOneWidget, reason: 'back on Today');

    await tester.tap(find.text('Fix shelf'));
    await tester.pumpAndSettle();
    expect(find.text('tasks hh-2 task=task-B occurrence=null'), findsOneWidget);
  });

  testWidgets('tapping the row does not complete it, and a second quick tap '
      'does not stack routes', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Water plants'));
    await tester.tap(find.text('Water plants'), warnIfMissed: false);
    await tester.pumpAndSettle();

    final config = router.routerDelegate.currentConfiguration;
    expect(config.matches.length, 1, reason: 'go replaces, never stacks');
    expect(
      config.uri.toString(),
      '/homes/hh-1/tasks?task=task-A&occurrence=occ-A2',
    );
    expect(find.byType(SnackBar), findsNothing);
  });
}
