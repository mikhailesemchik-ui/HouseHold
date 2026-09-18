import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:household_os/core/services/widget_settings.dart';
import 'package:household_os/features/today/domain/today_entry.dart';

@immutable
class WidgetRow {
  const WidgetRow({required this.title, required this.detail});

  final String title;
  final String detail;
}

/// Converts grouped Today sections into a small sanitized snapshot and writes
/// it to the home-screen widget via the home_widget shared data channel.
class WidgetSnapshotService {
  static const _androidName = 'HouseholdOsWidgetProvider';
  static const _androidQualified =
      'com.household.household_os.HouseholdOsWidgetProvider';
  static const _iosName = 'HouseholdOsWidget';

  /// Debounce: skip if less than 2 s have elapsed since the last update.
  static DateTime? _lastUpdateTime;

  /// Builds up to 3 display rows from sections using overdue → today → upcoming
  /// priority. Returns an empty list when no scheduled entries are available.
  static List<WidgetRow> buildRows({
    required Map<String, List<TodayEntry>> sections,
    required DateTime now,
  }) {
    final rows = <WidgetRow>[];
    final candidates = [
      ...?sections['overdue'],
      ...?sections['today'],
      ...?sections['upcoming'],
    ];
    for (final entry in candidates) {
      if (rows.length >= 3) break;
      final scheduled = entry.scheduledAt;
      if (scheduled == null) continue;
      final timeLabel = _formatDate(scheduled, now);
      rows.add(
        WidgetRow(
          title: entry.title,
          detail: '${entry.householdName} · $timeLabel',
        ),
      );
    }
    return rows;
  }

  static String _formatDate(DateTime utc, DateTime now) {
    final local = utc.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final tomorrow = today.add(const Duration(days: 1));
    final localDay = DateTime(local.year, local.month, local.day);
    if (localDay == today) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (localDay == yesterday) return 'Yesterday';
    if (localDay == tomorrow) return 'Tomorrow';
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

  /// Writes the current snapshot and triggers a widget redraw.
  /// Silently skips if called too soon after a previous update.
  static Future<void> update({
    required Map<String, List<TodayEntry>> sections,
    required DateTime now,
  }) async {
    final last = _lastUpdateTime;
    if (last != null && now.difference(last).inSeconds < 2) return;
    _lastUpdateTime = now;

    final mode = await WidgetSettings.getPrivacyMode();
    final overdueCount = sections['overdue']!.length;
    final todayCount = sections['today']!.length;

    await HomeWidget.saveWidgetData<int>('widget_overdue_count', overdueCount);
    await HomeWidget.saveWidgetData<int>('widget_today_count', todayCount);
    await HomeWidget.saveWidgetData<String>(
      'widget_privacy',
      mode == WidgetPrivacyMode.showNames ? 'show_names' : 'counts_only',
    );
    await HomeWidget.saveWidgetData<String>(
      'widget_updated_at',
      now.toUtc().toIso8601String(),
    );

    if (mode == WidgetPrivacyMode.showNames) {
      final rows = buildRows(sections: sections, now: now);
      for (var i = 0; i < 3; i++) {
        final row = i < rows.length ? rows[i] : null;
        await HomeWidget.saveWidgetData<String>(
          'widget_row_${i}_title',
          row?.title ?? '',
        );
        await HomeWidget.saveWidgetData<String>(
          'widget_row_${i}_detail',
          row?.detail ?? '',
        );
      }
    } else {
      for (var i = 0; i < 3; i++) {
        await HomeWidget.saveWidgetData<String>('widget_row_${i}_title', '');
        await HomeWidget.saveWidgetData<String>('widget_row_${i}_detail', '');
      }
    }

    await HomeWidget.updateWidget(
      name: _androidName,
      iOSName: _iosName,
      qualifiedAndroidName: _androidQualified,
    );
  }
}
