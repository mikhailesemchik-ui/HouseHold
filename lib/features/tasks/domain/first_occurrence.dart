import 'package:household_os/features/tasks/domain/recurrence_type.dart';

/// A selected time at most this long ago still counts as "start now".
const firstOccurrenceGrace = Duration(minutes: 2);

/// A selected time less than this far ahead may already be stale when the
/// server receives the request, so it is treated like a time that just passed.
const firstOccurrenceSafeLead = Duration(seconds: 15);

/// Minimum lead the adjusted start keeps over the moment of saving.
const firstOccurrenceMinLead = Duration(seconds: 60);

enum FirstOccurrenceOutcome {
  /// Submit the selected time as it is.
  unchanged,

  /// The selected time had just passed: submit [FirstOccurrenceDecision.dueAt].
  adjusted,

  /// The selected time has passed and is deliberately not moved, so the server
  /// will skip it (it never backfills slots earlier than the save instant).
  passedSkipped,
}

class FirstOccurrenceDecision {
  const FirstOccurrenceDecision(this.outcome, this.dueAt);

  final FirstOccurrenceOutcome outcome;

  /// The UTC due time to submit.
  final DateTime dueAt;
}

/// Decides the first due time of a NEW recurring task.
///
/// The form defaults to the current minute and the server drops every slot
/// earlier than the moment the task is saved, so ordinary form-filling time
/// used to cost the first occurrence. A time that has only just passed
/// (within [firstOccurrenceGrace]) is moved to the next whole minute at least
/// [firstOccurrenceMinLead] ahead. Older times are never reinterpreted.
/// A move that would land on another local day is not made either.
FirstOccurrenceDecision resolveFirstOccurrence({
  required DateTime selected,
  required DateTime now,
  required RecurrenceType recurrence,
}) {
  final selectedUtc = selected.toUtc();
  FirstOccurrenceDecision keep(FirstOccurrenceOutcome outcome) =>
      FirstOccurrenceDecision(outcome, selectedUtc);

  if (recurrence == RecurrenceType.none ||
      selected.isAfter(now.add(firstOccurrenceSafeLead))) {
    return keep(FirstOccurrenceOutcome.unchanged);
  }

  final localSelected = selected.toLocal();
  final localNow = now.toLocal();
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  if (now.difference(selected) > firstOccurrenceGrace) {
    return keep(
      sameDay(localSelected, localNow)
          ? FirstOccurrenceOutcome.passedSkipped
          : FirstOccurrenceOutcome.unchanged,
    );
  }

  final earliest = now.add(firstOccurrenceMinLead);
  const minute = 60 * 1000;
  final ms = earliest.millisecondsSinceEpoch;
  final candidate = DateTime.fromMillisecondsSinceEpoch(
    ms % minute == 0 ? ms : ms - ms % minute + minute,
  );
  if (!sameDay(candidate.toLocal(), localSelected)) {
    return keep(FirstOccurrenceOutcome.passedSkipped);
  }
  return FirstOccurrenceDecision(
    FirstOccurrenceOutcome.adjusted,
    candidate.toUtc(),
  );
}
