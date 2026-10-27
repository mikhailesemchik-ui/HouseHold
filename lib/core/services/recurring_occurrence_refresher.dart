import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/today/data/today_repository.dart';

/// Runs the server-side recurring-occurrence refresh, which is user-wide (it
/// covers every household the caller is an active member of), so one call
/// serves Today, Tasks and app resume alike.
///
/// State is kept per signed-in user: overlapping calls for the same user share
/// one in-flight request, a success suppresses further calls for that user for
/// [minInterval], and one user's request or result never stands in for
/// another's. A failure is logged and swallowed (existing data stays visible)
/// and does not start the throttle, so the next trigger retries.
///
/// [run] is invoked synchronously from [refresh], while [currentUserId] still
/// names the user it was resolved for, so the request carries that user's
/// session even if the account changes while it is in flight.
class RecurringOccurrenceRefresher {
  RecurringOccurrenceRefresher({
    required this.currentUserId,
    required this.run,
    this.minInterval = const Duration(minutes: 15),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final String? Function() currentUserId;
  final Future<void> Function() run;
  final Duration minInterval;
  final DateTime Function() _now;

  final Map<String, Future<void>> _inFlight = {};
  final Map<String, DateTime> _lastSuccessAt = {};

  Future<void> refresh() {
    final String? userId;
    try {
      userId = currentUserId();
    } catch (e, st) {
      debugPrint('refreshRecurringOccurrences failed: $e\n$st');
      return Future<void>.value();
    }
    if (userId == null) return Future<void>.value();
    return _inFlight[userId] ??= _refresh(userId).whenComplete(() {
      _inFlight.remove(userId);
    });
  }

  Future<void> _refresh(String userId) async {
    try {
      if (_isThrottled(userId)) return;
      await run();
      _lastSuccessAt[userId] = _now();
    } catch (e, st) {
      debugPrint('refreshRecurringOccurrences failed: $e\n$st');
    }
  }

  // Reason: wall-clock time, not a Stopwatch, because the app is usually
  // resumed after the device slept and a monotonic clock may not advance
  // while asleep. A negative elapsed time means the clock was moved back, so
  // the stored timestamp is meaningless and the refresh is allowed.
  bool _isThrottled(String userId) {
    final lastAt = _lastSuccessAt[userId];
    if (lastAt == null) return false;
    final elapsed = _now().difference(lastAt);
    return !elapsed.isNegative && elapsed < minInterval;
  }
}

final recurringOccurrenceRefresherProvider =
    Provider<RecurringOccurrenceRefresher>((ref) {
      return RecurringOccurrenceRefresher(
        currentUserId: () => supabaseClient.auth.currentUser?.id,
        run: () =>
            TodayRepository(supabaseClient).refreshRecurringOccurrences(),
      );
    });
