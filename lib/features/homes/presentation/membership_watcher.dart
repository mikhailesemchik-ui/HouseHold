import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

/// Reacts to the current user's own membership changing remotely (an owner
/// removes them, or they rejoin) while the app keeps running.
///
/// A removed user can no longer read that household's events or member rows,
/// so the only signal they can still receive is their OWN membership row
/// (see `activeHouseholdIdsProvider`). When a household drops out of that set
/// this evicts its cached state and, if the user is inside it, returns them
/// to the Homes list. When a household appears in that set again (rejoin) its
/// caches, possibly filled with empty results while access was lost, are
/// evicted too. Mounted once at the shell root, which outlives every
/// household route. See FLOW-001 / FLOW-002.
///
/// It also owns the one app-resume refresh (MU-001): other members' changes
/// only reach cached household state through realtime events seen while a
/// household screen is open, so anything that happened while the app was
/// backgrounded or on another screen is evicted when the app resumes.
class MembershipWatcher extends ConsumerStatefulWidget {
  const MembershipWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MembershipWatcher> createState() => _MembershipWatcherState();
}

class _MembershipWatcherState extends ConsumerState<MembershipWatcher>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final homes = ref.read(homesProvider).asData?.value;
    if (homes == null) return;
    // Screens currently watching these refetch in place; unwatched caches are
    // dropped and refetch on next open.
    ref.invalidate(homesProvider);
    for (final home in homes) {
      _evictHouseholdCaches(ref, home.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<Set<String>>>(activeHouseholdIdsProvider, (
      previous,
      next,
    ) {
      final before = previous?.asData?.value;
      final now = next.asData?.value;
      if (before == null || now == null) return;
      final router = GoRouter.of(context);
      for (final id in before.difference(now)) {
        _refresh(
          ref,
          id,
          homesIsStale: (homes) => homes.any((h) => h.id == id),
        );
        final path = router.routerDelegate.currentConfiguration.uri.path;
        if (path == '/homes/$id' || path.startsWith('/homes/$id/')) {
          router.go('/homes');
        }
      }
      // Reactivation (or a new membership) while the app kept running: caches
      // filled while access was lost (empty/null) must not outlive it.
      for (final id in now.difference(before)) {
        _refresh(
          ref,
          id,
          homesIsStale: (homes) => !homes.any((h) => h.id == id),
        );
      }
    });
    return widget.child;
  }

  void _refresh(
    WidgetRef ref,
    String id, {
    required bool Function(List<Household>) homesIsStale,
  }) {
    // Local join/leave already updated the list; only refetch when a remote
    // change left it stale.
    final homes = ref.read(homesProvider).asData?.value;
    if (homes != null && homesIsStale(homes)) {
      ref.invalidate(homesProvider);
    }
    _evictHouseholdCaches(ref, id);
  }
}

void _evictHouseholdCaches(WidgetRef ref, String id) {
  ref.invalidate(householdByIdProvider(id));
  ref.invalidate(householdSummaryProvider(id));
  ref.invalidate(householdMembersProvider(id));
  ref.invalidate(householdInvitesProvider(id));
  ref.invalidate(householdRecentActivityProvider(id));
  ref.invalidate(householdAllActivityProvider(id));
  ref.invalidate(taskMembersProvider(id));
}
