import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/tasks/domain/first_occurrence.dart';
import 'package:household_os/features/tasks/domain/recurrence_type.dart';

// Every clock and selection below is a fixed local DateTime, so the result does
// not depend on the machine's time zone or the real time. The server drops
// recurring slots earlier than the save instant (recurrence_started_at), which
// is why a time that has only just passed needs to move.
void main() {
  FirstOccurrenceDecision decide(
    DateTime selected,
    DateTime now, [
    RecurrenceType type = RecurrenceType.weekly,
  ]) => resolveFirstOccurrence(selected: selected, now: now, recurrence: type);

  final selected = DateTime(2026, 10, 29, 17, 46);
  DateTime at(int h, int m, [int s = 0, int ms = 0]) =>
      DateTime(2026, 10, 29, h, m, s, ms);

  void expectAdjusted(FirstOccurrenceDecision d, DateTime local) {
    expect(d.outcome, FirstOccurrenceOutcome.adjusted);
    expect(d.dueAt.isUtc, isTrue);
    expect(d.dueAt, local.toUtc());
  }

  void expectKept(FirstOccurrenceDecision d, FirstOccurrenceOutcome outcome) {
    expect(d.outcome, outcome);
    expect(d.dueAt, selected.toUtc(), reason: 'the selected time is kept');
  }

  group('a time still ahead is never touched', () {
    test('weekly, three minutes ahead', () {
      final d = decide(at(17, 50), at(17, 47));
      expect(d.outcome, FirstOccurrenceOutcome.unchanged);
      expect(d.dueAt, at(17, 50).toUtc());
    });

    test('daily, three minutes ahead', () {
      final d = decide(at(17, 50), at(17, 47), RecurrenceType.daily);
      expect(d.outcome, FirstOccurrenceOutcome.unchanged);
    });

    test('16 seconds ahead is safe, 15 seconds ahead is not', () {
      expect(
        decide(at(17, 48), at(17, 47, 44)).outcome,
        FirstOccurrenceOutcome.unchanged,
      );
      expectAdjusted(decide(at(17, 48), at(17, 47, 45)), at(17, 49));
    });
  });

  group('a time that just passed starts at the next whole minute', () {
    test('weekly, 30 seconds ago', () {
      expectAdjusted(decide(selected, at(17, 46, 30)), at(17, 48));
    });

    test('daily, 90 seconds ago', () {
      expectAdjusted(
        decide(selected, at(17, 47, 30), RecurrenceType.daily),
        at(17, 49),
      );
    });

    test('the exact two-minute boundary still counts', () {
      expectAdjusted(decide(selected, at(17, 48)), at(17, 49));
    });

    test('exactly on the minute needs no rounding up', () {
      // now + 60 s is already a whole minute: lead is exactly 60 seconds.
      expectAdjusted(decide(selected, at(17, 46)), at(17, 47));
    });

    test('the lead is never under a minute', () {
      for (final s in [0, 1, 17, 30, 59]) {
        final now = at(17, 47, s, 500);
        final d = decide(selected, now);
        expect(d.outcome, FirstOccurrenceOutcome.adjusted);
        expect(
          d.dueAt.difference(now.toUtc()),
          greaterThanOrEqualTo(firstOccurrenceMinLead),
        );
        expect(d.dueAt.second, 0);
        expect(d.dueAt.millisecond, 0);
      }
    });
  });

  group('older times are never reinterpreted', () {
    test('just beyond two minutes on the same day is kept and flagged', () {
      expectKept(
        decide(selected, at(17, 48, 0, 1)),
        FirstOccurrenceOutcome.passedSkipped,
      );
    });

    test('several hours ago on the same day is kept and flagged', () {
      expectKept(
        decide(selected, at(22, 5)),
        FirstOccurrenceOutcome.passedSkipped,
      );
    });

    test('yesterday is kept, silently', () {
      expectKept(
        decide(selected, DateTime(2026, 10, 30, 8)),
        FirstOccurrenceOutcome.unchanged,
      );
    });

    test('a date weeks ago is kept, silently', () {
      expectKept(
        decide(selected, DateTime(2026, 12, 1, 8)),
        FirstOccurrenceOutcome.unchanged,
      );
    });
  });

  group('midnight', () {
    test('a move onto the next local day is not made', () {
      final late = DateTime(2026, 10, 29, 23, 59);
      final d = decide(late, DateTime(2026, 10, 29, 23, 59, 40));
      expect(d.outcome, FirstOccurrenceOutcome.passedSkipped);
      expect(d.dueAt, late.toUtc());
    });

    test('selected just before midnight, saved just after, is not moved', () {
      final late = DateTime(2026, 10, 29, 23, 59);
      final d = decide(late, DateTime(2026, 10, 30, 0, 0, 30));
      expect(d.outcome, FirstOccurrenceOutcome.passedSkipped);
      expect(d.dueAt, late.toUtc());
    });
  });

  group('only new recurring tasks are affected', () {
    test('a one-off with a past due time is left alone', () {
      final d = decide(selected, at(17, 47), RecurrenceType.none);
      expect(d.outcome, FirstOccurrenceOutcome.unchanged);
      expect(d.dueAt, selected.toUtc());
    });
  });
}
