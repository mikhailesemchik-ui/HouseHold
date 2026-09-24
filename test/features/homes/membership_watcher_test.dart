import 'dart:async' show StreamController;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/membership_watcher.dart';

// FLOW-001 regression. The real bug needs a removed user's client to receive
// its own household_members change (new RLS policy + publication, see the
// migration); a widget test can't exercise Postgres/Realtime. This proves the
// consumer side: once the membership stream reports a household gone, the
// stale Homes list is refetched and a user inside that household is sent back
// to Homes.
class _FakeHomes extends HomesNotifier {
  _FakeHomes(this.source);
  final List<Household> Function() source;
  @override
  Future<List<Household>> build() async => source();
}

Household _home(String id) => Household(
  id: id,
  name: 'QA $id',
  createdBy: 'u',
  createdAt: DateTime.utc(2026, 9, 1),
);

/// Mirrors the app: the watcher sits in a shell above both the Homes list and
/// the nested household route.
GoRouter _router() => GoRouter(
  initialLocation: '/homes/hh/tasks',
  routes: [
    ShellRoute(
      builder: (_, _, child) => MembershipWatcher(child: child),
      routes: [
        GoRoute(
          path: '/homes',
          builder: (_, _) => Consumer(
            builder: (context, ref, _) => Text(
              ref
                      .watch(homesProvider)
                      .asData
                      ?.value
                      .map((h) => h.name)
                      .join(',') ??
                  'loading',
            ),
          ),
          routes: [
            GoRoute(
              path: ':id/tasks',
              builder: (_, _) => const Text('inside household'),
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  testWidgets('remote removal refetches Homes and leaves the household', (
    tester,
  ) async {
    final membership = StreamController<Set<String>>();
    addTearDown(membership.close);
    var server = [_home('hh')];
    final router = _router();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homesProvider.overrideWith(() => _FakeHomes(() => server)),
          activeHouseholdIdsProvider.overrideWith((ref) => membership.stream),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    membership.add({'hh'});
    await tester.pumpAndSettle();
    expect(find.text('inside household'), findsOneWidget);

    // Owner removes this user: the backend list shrinks, their own membership
    // row flips to left, and the stream reports no active households.
    server = [];
    membership.add(<String>{});
    await tester.pumpAndSettle();

    expect(find.text('inside household'), findsNothing);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/homes');
    expect(find.text('QA hh'), findsNothing);
  });

  testWidgets('a membership change in another household is ignored', (
    tester,
  ) async {
    final membership = StreamController<Set<String>>();
    addTearDown(membership.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homesProvider.overrideWith(() => _FakeHomes(() => [_home('hh')])),
          activeHouseholdIdsProvider.overrideWith((ref) => membership.stream),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    membership.add({'hh', 'other'});
    await tester.pumpAndSettle();
    membership.add({'hh'});
    await tester.pumpAndSettle();
    expect(find.text('inside household'), findsOneWidget);
  });

  // FLOW-002: after a remote removal the household-scoped caches reload under
  // the removed identity and hold empty results. When the same membership
  // becomes active again in the same session those must be evicted and Homes
  // refetched, or the rejoined user sees stale zeros / "Home not found".
  testWidgets('remote reactivation refetches Homes and evicts stale caches', (
    tester,
  ) async {
    final membership = StreamController<Set<String>>();
    addTearDown(membership.close);
    var server = [_home('hh')];
    var summaryFetches = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homesProvider.overrideWith(() => _FakeHomes(() => server)),
          activeHouseholdIdsProvider.overrideWith((ref) => membership.stream),
          householdSummaryProvider('hh').overrideWith((ref) async {
            summaryFetches++;
            return HouseholdSummary(
              incompleteTaskCount: 0,
              incompleteShoppingCount: 0,
              expenseCount: 0,
              activeMemberCount: summaryFetches,
            );
          }),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/homes',
            routes: [
              ShellRoute(
                builder: (_, _, child) => MembershipWatcher(child: child),
                routes: [
                  GoRoute(
                    path: '/homes',
                    builder: (_, _) => Consumer(
                      builder: (context, ref, _) {
                        final homes =
                            ref.watch(homesProvider).asData?.value ?? const [];
                        final summary = ref
                            .watch(householdSummaryProvider('hh'))
                            .asData
                            ?.value;
                        return Text(
                          '${homes.map((h) => h.name).join(',')}|'
                          '${summary?.activeMemberCount}',
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    membership.add({'hh'});
    await tester.pumpAndSettle();
    expect(find.text('QA hh|1'), findsOneWidget);

    server = [];
    membership.add(<String>{});
    await tester.pumpAndSettle();
    expect(find.textContaining('QA hh'), findsNothing);

    // Rejoin: server list has the household again and the summary cache must
    // be refetched (fetch count 3 = initial, removal eviction, reactivation).
    server = [_home('hh')];
    membership.add({'hh'});
    await tester.pumpAndSettle();
    expect(find.text('QA hh|3'), findsOneWidget);
  });
}
