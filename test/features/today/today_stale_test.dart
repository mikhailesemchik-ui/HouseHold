import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/realtime_recovery.dart';
import 'package:household_os/core/services/recurring_occurrence_refresher.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';
import 'package:household_os/features/today/data/today_repository.dart';
import 'package:household_os/features/today/domain/today_entry.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';
import 'package:household_os/features/today/presentation/today_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _Rows = List<Map<String, dynamic>>;

/// Stand-in for the Supabase-backed repository: every call to a watch method
/// is a fresh connection the test can feed or break.
class _FakeRepo implements TodayRepository {
  final occurrences = <StreamController<_Rows>>[];
  final tasks = <StreamController<_Rows>>[];

  @override
  Stream<_Rows> watchAssignedOccurrenceRows() {
    final c = StreamController<_Rows>();
    occurrences.add(c);
    return c.stream;
  }

  @override
  Stream<_Rows> watchAssignedTaskRows() {
    final c = StreamController<_Rows>();
    tasks.add(c);
    return c.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHomes extends HomesNotifier {
  @override
  Future<List<Household>> build() async => const [];
}

Future<void> _wait([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// An unfinished, undated task row as Supabase returns it ("Anytime").
Map<String, dynamic> _task(String id, String title) => {
  'id': id,
  'household_id': 'hh',
  'title': title,
  'recurrence_type': 'none',
  'due_at': null,
  'completed_at': null,
};

void main() {
  late _FakeRepo repo;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WidgetSnapshotService.writer = (_, _, _) async {};
    repo = _FakeRepo();
    container = ProviderContainer(
      overrides: [
        todayRepositoryProvider.overrideWithValue(repo),
        todayRetryDelayProvider.overrideWithValue(
          const Duration(milliseconds: 4),
        ),
        homesProvider.overrideWith(_FakeHomes.new),
        recurringOccurrenceRefresherProvider.overrideWithValue(
          RecurringOccurrenceRefresher(
            currentUserId: () => null,
            run: () async {},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> open() async {
    container.listen(todayProvider, (_, _) {});
    await container.read(todayProvider.future);
  }

  bool stale() => container.read(todayProvider.notifier).isStale.value;
  List<String> anytimeTitles() => container
      .read(todayProvider)
      .requireValue['anytime']!
      .map((e) => e.title)
      .toList();

  // Uses up one stream's retries: 1 open + 3 retries = 4 errors.
  Future<void> exhaust(List<StreamController<_Rows>> connections) async {
    for (var i = 0; i < 4; i++) {
      connections.last.addError(StateError('down'));
      await _wait(60);
    }
  }

  test('T1 healthy: both streams deliver, no warning', () async {
    await open();
    repo.tasks.last.add([_task('t1', 'Water plants')]);
    repo.occurrences.last.add([]);
    await _wait();

    expect(stale(), isFalse);
    expect(anytimeTitles(), ['Water plants']);
  });

  test(
    'T2 a transient error that F14 recovers never raises the warning',
    () async {
      await open();
      repo.tasks.last.add([_task('t1', 'Water plants')]);
      await _wait();
      repo.tasks.last.addError(StateError('timedOut'));
      await _wait();
      expect(repo.tasks.length, 2, reason: 'F14 reopened it');
      expect(stale(), isFalse);
      repo.tasks.last.add([_task('t1', 'Water plants'), _task('t2', 'Fresh')]);
      await _wait();

      expect(stale(), isFalse);
      expect(anytimeTitles(), ['Water plants', 'Fresh']);
    },
  );

  test(
    'T3 an exhausted tasks stream raises the warning and keeps the data',
    () async {
      await open();
      repo.tasks.last.add([_task('t1', 'Water plants')]);
      repo.occurrences.last.add([]);
      await _wait();

      await exhaust(repo.tasks);

      expect(stale(), isTrue);
      expect(anytimeTitles(), ['Water plants']);
    },
  );

  test('T4 an exhausted occurrences stream raises the warning', () async {
    await open();
    repo.tasks.last.add([_task('t1', 'Water plants')]);
    await _wait();

    await exhaust(repo.occurrences);

    expect(stale(), isTrue);
    expect(anytimeTitles(), ['Water plants']);
  });

  test(
    'T5 and T6 partial recovery keeps the warning, full recovery clears it',
    () async {
      await open();
      repo.tasks.last.add([_task('t1', 'Old')]);
      repo.occurrences.last.add([]);
      await _wait();
      await exhaust(repo.tasks);
      await exhaust(repo.occurrences);
      expect(stale(), isTrue);

      repo.occurrences.last.add([]);
      await _wait();
      expect(stale(), isTrue, reason: 'tasks still failed: no false all-clear');

      repo.tasks.last.add([_task('t1', 'New')]);
      await _wait();
      expect(stale(), isFalse);
      expect(anytimeTitles(), ['New']);
    },
  );

  test(
    'T7 resuming reopens the stream but only data clears the warning',
    () async {
      await open();
      repo.tasks.last.add([_task('t1', 'Old')]);
      await _wait();
      await exhaust(repo.tasks);
      final opened = repo.tasks.length;

      container.read(realtimeResumeProvider.notifier).resumed();
      await _wait();
      expect(repo.tasks.length, opened + 1, reason: 'recovery attempted');
      expect(stale(), isTrue, reason: 'a resume is not a recovery');

      await exhaust(repo.tasks);
      expect(stale(), isTrue, reason: 'a new failure keeps the warning');

      container.read(realtimeResumeProvider.notifier).resumed();
      await _wait();
      repo.tasks.last.add([_task('t1', 'Back')]);
      await _wait();
      expect(stale(), isFalse);
    },
  );

  test('T8 Retry rebuilds the streams once, keeps data and the warning until '
      'data arrives', () async {
    await open();
    repo.tasks.last.add([_task('t1', 'Kept')]);
    await _wait();
    await exhaust(repo.tasks);
    final before = repo.tasks.length;
    final oldConnection = repo.tasks.last;

    container.invalidate(todayProvider);
    await container.read(todayProvider.future);
    await _wait();

    expect(repo.tasks.length, before + 1, reason: 'exactly one new connection');
    expect(oldConnection.hasListener, isFalse, reason: 'old one cancelled');
    expect(stale(), isTrue, reason: 'still failing: the warning stays');
    expect(anytimeTitles(), ['Kept']);

    repo.tasks.last.add([_task('t1', 'Kept')]);
    await _wait();
    expect(stale(), isFalse);
  });

  test('T9 disposing the scope cancels listeners and timers', () async {
    await open();
    repo.tasks.last.addError(StateError('about to retry'));
    await Future<void>.delayed(const Duration(milliseconds: 1));
    container.dispose();
    final opened = repo.tasks.length;
    await _wait();

    expect(repo.tasks.length, opened, reason: 'no reopen after disposal');
    expect(repo.tasks.any((c) => c.hasListener), isFalse);
    expect(repo.occurrences.any((c) => c.hasListener), isFalse);
  });

  test('T10 an empty snapshot after a failure counts as fresh data', () async {
    await open();
    repo.tasks.last.add([_task('t1', 'Gone soon')]);
    await _wait();
    await exhaust(repo.tasks);
    expect(stale(), isTrue);

    container.read(realtimeResumeProvider.notifier).resumed();
    await _wait();
    repo.tasks.last.add([]);
    await _wait();

    expect(stale(), isFalse);
    expect(anytimeTitles(), isEmpty);
  });

  group('Today screen', () {
    testWidgets('shows the warning above the kept tasks; Retry rebuilds', (
      tester,
    ) async {
      final notifier = _StaleFakeNotifier({
        'overdue': [],
        'today': [],
        'upcoming': [],
        'anytime': [_entry('Kept task')],
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [todayProvider.overrideWith(() => notifier)],
          child: const MaterialApp(home: TodayScreen()),
        ),
      );
      await tester.pump();
      expect(find.textContaining('may be out of date'), findsNothing);

      notifier.stale.value = true;
      await tester.pump();
      expect(find.text('Kept task'), findsOneWidget);
      expect(
        find.text(
          'Some tasks may be out of date. Check your connection and try again.',
        ),
        findsOneWidget,
      );

      final buildsBefore = notifier.builds;
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(
        notifier.builds,
        greaterThan(buildsBefore),
        reason: 'Retry rebuilt',
      );

      notifier.stale.value = false;
      await tester.pump();
      expect(find.textContaining('may be out of date'), findsNothing);
      expect(find.text('Kept task'), findsOneWidget);
    });

    testWidgets('the warning sits with the empty state, not instead of it', (
      tester,
    ) async {
      final notifier = _StaleFakeNotifier({
        'overdue': [],
        'today': [],
        'upcoming': [],
        'anytime': [],
      })..stale.value = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [todayProvider.overrideWith(() => notifier)],
          child: const MaterialApp(home: TodayScreen()),
        ),
      );
      await tester.pump();

      expect(find.textContaining('may be out of date'), findsOneWidget);
      expect(find.text('Nothing assigned to you.'), findsOneWidget);
    });
  });
}

TodayEntry _entry(String title) => TodayEntry(
  occurrenceId: null,
  taskId: 'task-$title',
  title: title,
  householdId: 'hh',
  householdName: 'Home',
  scheduledAt: null,
  recurrenceType: RecurrenceType.none,
  sourceType: TodayEntrySource.anytime,
);

class _StaleFakeNotifier extends TodayNotifier {
  _StaleFakeNotifier(this._sections);
  final Map<String, List<TodayEntry>> _sections;
  final ValueNotifier<bool> stale = ValueNotifier(false);
  int builds = 0;

  @override
  ValueListenable<bool> get isStale => stale;

  @override
  Future<Map<String, List<TodayEntry>>> build() async {
    builds++;
    return _sections;
  }

  @override
  Future<void> reconcileReminders() async {}

  @override
  Future<void> updateWidget() async {}
}
