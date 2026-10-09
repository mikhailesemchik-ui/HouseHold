import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:household_os/core/services/widget_settings.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

/// One row in the widget's personal task list.
@immutable
class WidgetTaskItem {
  const WidgetTaskItem({
    required this.id,
    required this.source,
    required this.title,
    required this.household,
    required this.label,
    required this.completed,
  });

  /// Occurrence id for scheduled tasks, task id for anytime tasks — the
  /// identifier the widget mutates when the row is tapped.
  final String id;

  /// `occurrence` or `anytime`; selects which TaskRepository method applies.
  final String source;
  final String title;
  final String household;

  /// Short scannable status: Overdue, Today, Anytime, a short date, or Done.
  final String label;
  final bool completed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'household': household,
    'label': label,
    'completed': completed,
  };
}

/// Converts Today data into a personal widget snapshot and writes it to the
/// home-screen widget via the home_widget shared data channel.
class WidgetSnapshotService {
  static const _androidName = 'HouseholdOsWidgetProvider';
  static const _androidQualified =
      'com.household.household_os.HouseholdOsWidgetProvider';
  static const _iosName = 'HouseholdOsWidget';
  static const _snapshotKey = 'widget_snapshot_json';

  static const _minInterval = Duration(seconds: 2);

  /// Non-null while inside the throttle window that follows a write.
  static Timer? _cooldown;

  /// Latest call that arrived inside the window; written once it closes.
  static ({
    Map<String, List<TodayEntry>> sections,
    List<TodayEntry> completedToday,
    DateTime now,
  })?
  _pending;

  /// Replaceable so tests can observe writes without the platform channel.
  @visibleForTesting
  static Future<void> Function(
    Map<String, List<TodayEntry>>,
    List<TodayEntry>,
    DateTime,
  )
  writer = _write;

  @visibleForTesting
  static void resetForTest() {
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
    writer = _write;
  }

  /// Orders active entries (overdue → today → anytime → upcoming) followed
  /// by entries completed today, and converts each to a display row. Bucket
  /// labels trust which section an entry is already in — the caller (Today's
  /// own grouping) is the single source of truth for overdue/today/upcoming.
  static List<WidgetTaskItem> buildItems({
    required Map<String, List<TodayEntry>> sections,
    required List<TodayEntry> completedToday,
  }) {
    final items = <WidgetTaskItem>[
      ...?sections['overdue']?.map((e) => _toItem(e, label: 'Overdue')),
      ...?sections['today']?.map((e) => _toItem(e, label: 'Today')),
      ...?sections['anytime']?.map((e) => _toItem(e, label: 'Anytime')),
      ...?sections['upcoming']?.map(
        (e) => _toItem(e, label: _shortDate(e.scheduledAt!)),
      ),
    ];

    final sortedCompleted = [...completedToday]
      ..sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
    items.addAll(
      sortedCompleted.map((e) => _toItem(e, label: 'Done', completed: true)),
    );
    return items;
  }

  static WidgetTaskItem _toItem(
    TodayEntry entry, {
    required String label,
    bool completed = false,
  }) {
    return WidgetTaskItem(
      id: entry.occurrenceId ?? entry.taskId,
      source: entry.sourceType == TodayEntrySource.occurrence
          ? 'occurrence'
          : 'anytime',
      title: entry.title,
      household: entry.householdName,
      label: label,
      completed: completed,
    );
  }

  static String _shortDate(DateTime utc) {
    final local = utc.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${weekdays[local.weekday - 1]} ${local.day} ${months[local.month - 1]}';
  }

  /// Writes the snapshot immediately, or, inside the throttle window, keeps
  /// only the latest call and writes it once when the window closes.
  static Future<void> update({
    required Map<String, List<TodayEntry>> sections,
    required List<TodayEntry> completedToday,
    required DateTime now,
  }) async {
    if (_cooldown != null) {
      _pending = (sections: sections, completedToday: completedToday, now: now);
      return;
    }
    _cooldown = Timer(_minInterval, _flushPending);
    await writer(sections, completedToday, now);
  }

  static void _flushPending() {
    _cooldown = null;
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    update(
      sections: pending.sections,
      completedToday: pending.completedToday,
      now: pending.now,
    ).ignore();
  }

  static Future<void> _write(
    Map<String, List<TodayEntry>> sections,
    List<TodayEntry> completedToday,
    DateTime now,
  ) async {
    final mode = await WidgetSettings.getPrivacyMode();
    final overdueCount = sections['overdue']!.length;
    final todayCount = sections['today']!.length;
    final activeCount = sections.values.fold<int>(
      0,
      (sum, entries) => sum + entries.length,
    );
    final showNames = mode == WidgetPrivacyMode.showNames;

    final payload = {
      'overdueCount': overdueCount,
      'todayCount': todayCount,
      'activeCount': activeCount,
      'completedTodayCount': completedToday.length,
      'privacy': showNames ? 'show_names' : 'counts_only',
      'updatedAt': now.toUtc().toIso8601String(),
      'tasks': showNames
          ? buildItems(
              sections: sections,
              completedToday: completedToday,
            ).map((e) => e.toJson()).toList()
          : const [],
    };

    await HomeWidget.saveWidgetData<String>(_snapshotKey, jsonEncode(payload));

    await HomeWidget.updateWidget(
      name: _androidName,
      iOSName: _iosName,
      qualifiedAndroidName: _androidQualified,
    );
  }
}
