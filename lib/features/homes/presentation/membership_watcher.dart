import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/tasks/presentation/tasks_provider.dart';

/// Reacts to the current user losing a household membership remotely (e.g.
/// an owner removes them) while the app keeps running.
///
/// A removed user can no longer read that household's events or member rows,
/// so the only signal they can still receive is their OWN membership row
/// (see `activeHouseholdIdsProvider`). When a household drops out of that set
/// this evicts its cached state and, if the user is inside it, returns them
/// to the Homes list. Mounted once at the shell root, which outlives every
/// household route. See FLOW-001.
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
        _evict(ref, id);
        final path = router.routerDelegate.currentConfiguration.uri.path;
        if (path == '/homes/$id' || path.startsWith('/homes/$id/')) {
          router.go('/homes');
        }
      }
    });
    return child;
  }

  void _evict(WidgetRef ref, String id) {
    // Local leave already removed it from the list; only refetch when a
    // remote removal left the list stale.
    final homes = ref.read(homesProvider).asData?.value;
    if (homes != null && homes.any((h) => h.id == id)) {
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
