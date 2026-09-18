import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/widgets/app_activity_row.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';

/// Groups already-sorted (newest-first) events into a flat render list:
/// a `String` day label followed by the [HouseholdEvent]s that occurred on
/// that local day, repeating whenever the day changes. Deterministic and
/// local — no locale/date-package complexity beyond what the app already
/// formats elsewhere (matches the Expenses history's own day labelling).
List<Object> groupActivityByDay(List<HouseholdEvent> events) {
  final result = <Object>[];
  String? lastLabel;
  for (final event in events) {
    final label = _dayLabel(event.occurredAt);
    if (label != lastLabel) {
      result.add(label);
      lastLabel = label;
    }
    result.add(event);
  }
  return result;
}

String _dayLabel(DateTime utc) {
  final local = utc.toLocal();
  final now = DateTime.now();
  if (_isSameDay(local, now)) return 'Today';
  final yesterday = now.subtract(const Duration(days: 1));
  if (_isSameDay(local, yesterday)) return 'Yesterday';
  const months = [
    '',
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
  return '${local.day} ${months[local.month]}';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key, required this.householdId});

  final String householdId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityAsync = ref.watch(householdAllActivityProvider(householdId));
    // The header is ordinary scrollable content now (not a pinned `AppBar`)
    // — every branch below places it as the first item of its own
    // scrollable, so it scrolls away with the page and returns naturally
    // at the top.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Activity',
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: activityAsync.when(
          loading: () => ListView(
            children: const [
              header,
              AppSkeletonList(sectionCounts: {'': 6}, scrollable: false),
            ],
          ),
          error: (_, _) => ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load activity. Please try again.',
                onRetry: () =>
                    ref.invalidate(householdAllActivityProvider(householdId)),
              ),
            ],
          ),
          data: (events) {
            if (events.isEmpty) {
              return ListView(
                children: const [
                  header,
                  AppEmptyState(title: 'No activity yet'),
                ],
              );
            }
            final rows = groupActivityByDay(events);
            return RefreshIndicator(
              onRefresh: () =>
                  ref.refresh(householdAllActivityProvider(householdId).future),
              // Backend history fetch has no LIMIT (documented, not solved
              // here) — the list stays lazy in rendering regardless of how
              // much data the provider ends up holding. +1 item for the
              // header, kept in the same lazy builder-backed list.
              child: ListView.builder(
                itemCount: rows.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) return header;
                  final row = rows[i - 1];
                  if (row is String) {
                    return AppSectionHeader(label: row);
                  }
                  return AppActivityRow(event: row as HouseholdEvent);
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
