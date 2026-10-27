import 'package:household_os/core/services/notification_service.dart';
import 'package:household_os/core/services/widget_snapshot.dart';
import 'package:household_os/features/expenses/data/financial_request_store.dart';
import 'package:household_os/features/profile/data/account_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Removes what the device still holds for a deleted account: that user's
/// unresolved financial request ids, scheduled reminders and the home-screen
/// widget contents. Settings and other users' entries are left alone.
///
/// A marker records that a deletion was attempted. If the app is killed
/// between the server's confirmation and this cleanup, the next launch asks
/// the server whether the account is gone and finishes the job. Every step is
/// safe to repeat. This only affects local data: server-side idempotency for
/// active users is untouched.
class AccountLocalCleanup {
  AccountLocalCleanup(this._prefs, {Future<void> Function()? clearDeviceData})
    : _clearDeviceData = clearDeviceData ?? clearRemindersAndWidget;

  final SharedPreferences _prefs;
  final Future<void> Function() _clearDeviceData;

  static const _markerKey = 'account_deletion_attempt_user';

  String? get markedUserId => _prefs.getString(_markerKey);

  Future<void> mark(String userId) => _prefs.setString(_markerKey, userId);

  Future<void> unmark() => _prefs.remove(_markerKey);

  /// Cleans up after a confirmed deletion of [userId], then ends the local
  /// session. The marker is removed last so an interrupted run repeats.
  Future<void> finish(String userId, AccountRepository repo) async {
    await FinancialRequestStore(_prefs).clearUser(userId);
    try {
      await _clearDeviceData();
    } catch (_) {
      // Best effort: reminders and the widget are rebuilt from the next
      // account's data anyway.
    }
    await repo.endLocalSession();
    await unmark();
  }

  /// On launch: complete a cleanup that was interrupted, or forget a marker
  /// whose deletion never happened. Does nothing while the answer is unknown.
  Future<void> resumeIfPending(AccountRepository repo) async {
    final userId = markedUserId;
    if (userId == null) return;
    final gone = await repo.isAccountGone(userId);
    if (gone == null) return;
    if (gone) {
      await finish(userId, repo);
    } else {
      await unmark();
    }
  }
}

/// Cancels scheduled reminders and blanks the widget (best effort).
Future<void> clearRemindersAndWidget() async {
  await notificationService.cancelAll();
  await WidgetSnapshotService.update(
    sections: {
      'overdue': const [],
      'today': const [],
      'anytime': const [],
      'upcoming': const [],
    },
    completedToday: const [],
    now: DateTime.now(),
  );
}
