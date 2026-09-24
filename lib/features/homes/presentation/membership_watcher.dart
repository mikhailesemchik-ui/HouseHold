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
class MembershipWatcher extends ConsumerWidget {
  const MembershipWatcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    return child;
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
    ref.invalidate(householdByIdProvider(id));
    ref.invalidate(householdSummaryProvider(id));
    ref.invalidate(householdMembersProvider(id));
    ref.invalidate(householdInvitesProvider(id));
    ref.invalidate(householdRecentActivityProvider(id));
    ref.invalidate(householdAllActivityProvider(id));
    ref.invalidate(taskMembersProvider(id));
  }
}
