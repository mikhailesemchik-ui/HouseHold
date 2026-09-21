import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/domain/household_invite.dart';
import 'package:household_os/features/homes/domain/household_member_info.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/presentation/activity_screen.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';
import 'package:household_os/features/homes/presentation/household_detail_screen.dart';
import 'package:household_os/features/homes/presentation/members_screen.dart';

Map<String, dynamic> baseEventMap({
  String id = 'ev-1',
  String householdId = 'hh-1',
  String? actorUserId = 'user-1',
  String? actorDisplayName = 'Alice',
  String eventType = 'task_created',
  String entityType = 'task',
  String? entityId = 'entity-1',
  String titleSnapshot = 'Clean kitchen',
  int? amountCents,
  String? currency,
  String occurredAt = '2026-08-27T10:00:00.000Z',
}) => {
  'id': id,
  'household_id': householdId,
  'actor_user_id': actorUserId,
  'actor_display_name': actorDisplayName,
  'event_type': eventType,
  'entity_type': entityType,
  'entity_id': entityId,
  'title_snapshot': titleSnapshot,
  'amount_cents': amountCents,
  'currency': currency,
  'occurred_at': occurredAt,
};

HouseholdEvent makeEvent({
  String actorDisplayName = 'Alice',
  String eventType = 'task_created',
  String titleSnapshot = 'Clean kitchen',
  int? amountCents,
  String? currency,
}) => HouseholdEvent.fromMap(
  baseEventMap(
    actorDisplayName: actorDisplayName,
    eventType: eventType,
    titleSnapshot: titleSnapshot,
    amountCents: amountCents,
    currency: currency,
  ),
);

HouseholdMemberInfo makeMember({
  String userId = 'user-1',
  String displayName = 'Alice',
  String publicId = 'alice#1234',
  String role = 'member',
}) => HouseholdMemberInfo(
  userId: userId,
  displayName: displayName,
  publicId: publicId,
  role: role,
  joinedAt: DateTime.utc(2026, 8, 1),
);

const _testSummary = HouseholdSummary(
  incompleteTaskCount: 3,
  incompleteShoppingCount: 2,
  expenseCount: 5,
  activeMemberCount: 4,
);

/// Wraps [screen] in a stand-in for the app shell — the same
/// `Scaffold(extendBody: true)` + bottom navigation arrangement that publishes
/// the nav bar's measured height as `MediaQuery.padding.bottom`.
Widget inShell(Widget screen, {required double navBarHeight}) {
  return Scaffold(
    extendBody: true,
    bottomNavigationBar: SizedBox(height: navBarHeight),
    body: screen,
  );
}

/// Bottom padding a `ListView`/`ListView.builder` actually applies, whether it
/// declared its own padding or consumed `MediaQuery.padding` automatically.
double effectiveListBottomPadding(WidgetTester tester) {
  final sliverPadding = tester.widget<SliverPadding>(
    find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(SliverPadding),
        )
        .first,
  );
  return (sliverPadding.padding as EdgeInsets).bottom;
}

Widget buildActivityScreen(
  List<HouseholdEvent> events, {
  double? navBarHeight,
}) {
  const screen = ActivityScreen(householdId: 'test-hh');
  return ProviderScope(
    overrides: [
      householdAllActivityProvider(
        'test-hh',
      ).overrideWith((ref) async => events),
    ],
    child: MaterialApp(
      home: navBarHeight == null
          ? screen
          : inShell(screen, navBarHeight: navBarHeight),
    ),
  );
}

Widget buildDashboardScreen({
  double? navBarHeight,
  List<HouseholdInvite> invites = const [],
}) {
  final recentEvents = [
    makeEvent(eventType: 'expense_created', titleSnapshot: 'Electricity'),
  ];
  const screen = HouseholdDetailScreen(householdId: 'test-hh');
  return ProviderScope(
    overrides: [
      householdByIdProvider('test-hh').overrideWith(
        (ref) async => Household(
          id: 'test-hh',
          name: 'Test Home',
          createdBy: 'user-1',
          createdAt: DateTime.utc(2026, 8, 1),
        ),
      ),
      householdSummaryProvider(
        'test-hh',
      ).overrideWith((ref) async => _testSummary),
      householdInvitesProvider('test-hh').overrideWith((ref) async => invites),
      householdRecentActivityProvider(
        'test-hh',
      ).overrideWith((ref) async => recentEvents),
    ],
    child: MaterialApp(
      theme: appTheme,
      home: navBarHeight == null
          ? screen
          : inShell(screen, navBarHeight: navBarHeight),
    ),
  );
}

Rect tileRectFor(WidgetTester tester, String label) {
  final inkWellFinder = find
      .ancestor(of: find.text(label), matching: find.byType(InkWell))
      .first;
  return tester.getRect(inkWellFinder);
}

Widget buildMembersScreen(
  List<HouseholdMemberInfo> members, {
  String currentUserId = 'user-1',
  Future<void> Function(String householdId, String userId)? removeMember,
  Future<void> Function(String householdId, String newOwnerId)?
  transferOwnership,
  double? navBarHeight,
}) {
  final screen = MembersScreen(
    householdId: 'test-hh',
    currentUserIdOverride: currentUserId,
    removeMemberOverride: removeMember,
    transferOwnershipOverride: transferOwnership,
  );
  return ProviderScope(
    overrides: [
      householdMembersProvider('test-hh').overrideWith((ref) async => members),
    ],
    child: MaterialApp(
      home: navBarHeight == null
          ? screen
          : inShell(screen, navBarHeight: navBarHeight),
    ),
  );
}

void main() {
  group('HouseholdEvent.fromMap', () {
    test('parses all fields', () {
      final event = HouseholdEvent.fromMap(baseEventMap());
      expect(event.id, 'ev-1');
      expect(event.householdId, 'hh-1');
      expect(event.actorUserId, 'user-1');
      expect(event.actorDisplayName, 'Alice');
      expect(event.eventType, 'task_created');
      expect(event.entityType, 'task');
      expect(event.entityId, 'entity-1');
      expect(event.titleSnapshot, 'Clean kitchen');
      expect(event.amountCents, isNull);
      expect(event.currency, isNull);
    });

    test('parses amount_cents for expense events', () {
      final event = HouseholdEvent.fromMap(
        baseEventMap(
          eventType: 'expense_created',
          amountCents: 8240,
          currency: 'EUR',
        ),
      );
      expect(event.amountCents, 8240);
      expect(event.currency, 'EUR');
    });

    test('falls back to Deleted member when actor_display_name is null', () {
      final event = HouseholdEvent.fromMap(
        baseEventMap(actorDisplayName: null),
      );
      expect(event.actorDisplayName, 'Deleted member');
    });

    test('handles null actor_user_id gracefully', () {
      final event = HouseholdEvent.fromMap(baseEventMap(actorUserId: null));
      expect(event.actorUserId, isNull);
      expect(event.actorDisplayName, 'Alice');
    });
  });

  group('HouseholdEvent.displayText', () {
    test('task_created', () {
      final event = makeEvent(
        eventType: 'task_created',
        titleSnapshot: 'Clean kitchen',
      );
      expect(event.displayText, 'Alice created "Clean kitchen"');
    });

    test('task_completed', () {
      final event = makeEvent(
        eventType: 'task_completed',
        titleSnapshot: 'Clean kitchen',
      );
      expect(event.displayText, 'Alice completed "Clean kitchen"');
    });

    test('task_reopened', () {
      final event = makeEvent(
        eventType: 'task_reopened',
        titleSnapshot: 'Clean kitchen',
      );
      expect(event.displayText, 'Alice reopened "Clean kitchen"');
    });

    test('task_deleted', () {
      final event = makeEvent(
        eventType: 'task_deleted',
        titleSnapshot: 'Clean kitchen',
      );
      expect(event.displayText, 'Alice deleted "Clean kitchen"');
    });

    test('shopping_item_added', () {
      final event = makeEvent(
        eventType: 'shopping_item_added',
        titleSnapshot: 'Milk',
      );
      expect(event.displayText, 'Alice added "Milk"');
    });

    test('shopping_item_completed', () {
      final event = makeEvent(
        eventType: 'shopping_item_completed',
        titleSnapshot: 'Milk',
      );
      expect(event.displayText, 'Alice completed "Milk"');
    });

    test('expense_created with amount', () {
      final event = makeEvent(
        eventType: 'expense_created',
        titleSnapshot: 'Electricity',
        amountCents: 8240,
        currency: 'EUR',
      );
      expect(
        event.displayText,
        'Alice added expense "Electricity" - \u20ac82.40',
      );
    });

    test('expense_created without amount falls back gracefully', () {
      final event = makeEvent(
        eventType: 'expense_created',
        titleSnapshot: 'Lunch',
      );
      expect(event.displayText, 'Alice added expense "Lunch"');
    });

    test('expense_deleted', () {
      final event = makeEvent(
        eventType: 'expense_deleted',
        titleSnapshot: 'Lunch',
      );
      expect(event.displayText, 'Alice deleted expense "Lunch"');
    });

    test('deleted member fallback in displayText', () {
      final event = makeEvent(
        actorDisplayName: 'Deleted member',
        eventType: 'task_completed',
        titleSnapshot: 'Clean kitchen',
      );
      expect(event.displayText, 'Deleted member completed "Clean kitchen"');
    });

    test('expense amount formatting EUR', () {
      final event = makeEvent(
        eventType: 'expense_created',
        titleSnapshot: 'Gas',
        amountCents: 100,
        currency: 'EUR',
      );
      expect(event.displayText, 'Alice added expense "Gas" - \u20ac1.00');
    });

    test('expense amount formatting USD', () {
      final event = makeEvent(
        eventType: 'expense_created',
        titleSnapshot: 'Coffee',
        amountCents: 450,
        currency: 'USD',
      );
      expect(event.displayText, 'Alice added expense "Coffee" - \$4.50');
    });

    test('unknown event type has non-empty fallback', () {
      final event = makeEvent(eventType: 'unknown_type');
      expect(event.displayText, isNotEmpty);
    });

    test('member_joined', () {
      final event = HouseholdEvent.fromMap({
        ...baseEventMap(eventType: 'member_joined', entityType: 'member'),
        'title_snapshot': null,
      });
      expect(event.displayText, 'Alice joined');
    });

    test('member_left', () {
      final event = HouseholdEvent.fromMap({
        ...baseEventMap(eventType: 'member_left', entityType: 'member'),
        'title_snapshot': null,
      });
      expect(event.displayText, 'Alice left');
    });

    test('member_removed names the removed member', () {
      final event = makeEvent(
        eventType: 'member_removed',
        titleSnapshot: 'Bob',
      );
      expect(event.displayText, 'Alice removed Bob');
    });

    test('ownership_transferred names the new owner', () {
      final event = makeEvent(
        eventType: 'ownership_transferred',
        titleSnapshot: 'Carol',
      );
      expect(event.displayText, 'Alice transferred ownership to Carol');
    });
  });

  group('ActivityScreen widget', () {
    testWidgets('shows real screen shell with local loading while pending', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdAllActivityProvider(
              'test-hh',
            ).overrideWith((ref) => Completer<List<HouseholdEvent>>().future),
          ],
          child: const MaterialApp(
            home: ActivityScreen(householdId: 'test-hh'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Activity'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows empty state when no events', (tester) async {
      await tester.pumpWidget(buildActivityScreen([]));
      await tester.pump();
      expect(find.text('No activity yet'), findsOneWidget);
    });

    testWidgets('shows event displayText in list', (tester) async {
      final events = [
        makeEvent(eventType: 'task_completed', titleSnapshot: 'Clean kitchen'),
      ];
      await tester.pumpWidget(buildActivityScreen(events));
      await tester.pump();
      expect(find.textContaining('Clean kitchen'), findsOneWidget);
    });

    testWidgets('shows multiple events', (tester) async {
      final events = [
        makeEvent(eventType: 'task_created', titleSnapshot: 'Task A'),
        makeEvent(eventType: 'shopping_item_added', titleSnapshot: 'Milk'),
      ];
      await tester.pumpWidget(buildActivityScreen(events));
      await tester.pump();
      expect(find.textContaining('Task A'), findsOneWidget);
      expect(find.textContaining('Milk'), findsOneWidget);
    });

    testWidgets('last event clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      final events = [
        makeEvent(eventType: 'task_created', titleSnapshot: 'Task A'),
      ];

      await tester.pumpWidget(buildActivityScreen(events));
      await tester.pumpAndSettle();
      final withoutShell = effectiveListBottomPadding(tester);

      await tester.pumpWidget(
        buildActivityScreen(events, navBarHeight: navBarHeight),
      );
      await tester.pumpAndSettle();
      final withShell = effectiveListBottomPadding(tester);

      // This list declares no padding, so it consumes MediaQuery.padding
      // itself — the nav height lands exactly once, with nothing to maintain.
      expect(withShell - withoutShell, navBarHeight);
      expect(withShell, navBarHeight);
    });

    testWidgets('pull-to-refresh re-fetches activity', (tester) async {
      var fetchCount = 0;
      final events = [
        makeEvent(eventType: 'task_created', titleSnapshot: 'Task A'),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdAllActivityProvider('test-hh').overrideWith((ref) async {
              fetchCount++;
              return events;
            }),
          ],
          child: const MaterialApp(
            home: ActivityScreen(householdId: 'test-hh'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fetchCount, 1);

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(fetchCount, greaterThan(1));
    });

    testWidgets('long event description renders without overflow', (
      tester,
    ) async {
      final events = [
        makeEvent(
          eventType: 'task_created',
          titleSnapshot:
              'Deep clean the entire upstairs bathroom including the grout '
              'and the extractor fan above the shower',
        ),
      ];
      await tester.pumpWidget(buildActivityScreen(events));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders many events at 2.0x text scale without overflow', (
      tester,
    ) async {
      final events = [
        for (var i = 0; i < 15; i++)
          makeEvent(eventType: 'task_created', titleSnapshot: 'Task $i'),
      ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2.0),
          ),
          child: buildActivityScreen(events),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('groupActivityByDay', () {
    test('inserts one day label per distinct day, in event order', () {
      final today = makeEvent(
        eventType: 'task_created',
        titleSnapshot: 'Today task',
      );
      final events = [today];
      final grouped = groupActivityByDay(events);
      expect(grouped.first, isA<String>());
      expect(grouped[1], today);
    });

    test('does not repeat the label for consecutive same-day events', () {
      final e1 = HouseholdEvent.fromMap(
        baseEventMap(id: 'e1', occurredAt: '2026-08-27T10:00:00.000Z'),
      );
      final e2 = HouseholdEvent.fromMap(
        baseEventMap(id: 'e2', occurredAt: '2026-08-27T11:00:00.000Z'),
      );
      final grouped = groupActivityByDay([e2, e1]);
      // One label, then both events — no label repeated between them.
      expect(grouped.whereType<String>().length, 1);
      expect(grouped.length, 3);
    });

    test('empty input produces an empty result', () {
      expect(groupActivityByDay(const []), isEmpty);
    });
  });

  group('MembersScreen widget', () {
    testWidgets('last member clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      final members = [makeMember(displayName: 'Alice')];

      await tester.pumpWidget(buildMembersScreen(members));
      await tester.pumpAndSettle();
      final withoutShell = effectiveListBottomPadding(tester);

      await tester.pumpWidget(
        buildMembersScreen(members, navBarHeight: navBarHeight),
      );
      await tester.pumpAndSettle();
      final withShell = effectiveListBottomPadding(tester);

      // This list now declares its own padding (Phase 5: rows became
      // individual `AppSoftCard`s, needing horizontal margins the automatic
      // MediaQuery consumption cannot provide), so it re-applies the nav
      // clearance by hand exactly once, plus its own base inset.
      expect(withShell - withoutShell, navBarHeight);
      expect(withShell, navBarHeight + AppSpacing.base);
    });

    testWidgets('shows real screen shell with local loading while pending', (
      tester,
    ) async {
      final provider = householdMembersProvider('test-hh');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            provider.overrideWith(
              (ref) => Completer<List<HouseholdMemberInfo>>().future,
            ),
          ],
          child: const MaterialApp(
            home: MembersScreen(
              householdId: 'test-hh',
              currentUserIdOverride: 'user-1',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Members'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows member display name', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([makeMember(displayName: 'Alice')]),
      );
      await tester.pump();
      expect(find.textContaining('Alice'), findsOneWidget);
    });

    testWidgets('shows the current user their own public ID on their own row', (
      tester,
    ) async {
      // makeMember and buildMembersScreen both default userId to 'user-1',
      // so this member row is the viewer's own row.
      await tester.pumpWidget(
        buildMembersScreen([makeMember(publicId: 'alice#1234')]),
      );
      await tester.pump();
      expect(find.text('alice#1234'), findsOneWidget);
    });

    testWidgets("does not show another member's public ID on the main list "
        '(privacy rule)', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-2', publicId: 'bob#5678'),
        ], currentUserId: 'user-1'),
      );
      await tester.pump();
      expect(find.text('bob#5678'), findsNothing);
    });

    testWidgets('shows Owner role as plain text metadata', (tester) async {
      // Default member/current-user IDs coincide, so this is also the
      // viewer's own row — role and "You" combine into one plain-text line.
      await tester.pumpWidget(buildMembersScreen([makeMember(role: 'owner')]));
      await tester.pump();
      expect(find.text('Owner · You'), findsOneWidget);
    });

    testWidgets('does not show Owner metadata for a regular, non-self member', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(role: 'member'),
        ], currentUserId: 'someone-else'),
      );
      await tester.pump();
      expect(find.textContaining('Owner'), findsNothing);
    });

    testWidgets('shows multiple members', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(displayName: 'Alice', role: 'owner'),
          makeMember(
            userId: 'user-2',
            displayName: 'Bob',
            publicId: 'bob#5678',
          ),
        ]),
      );
      await tester.pump();
      expect(find.textContaining('Alice'), findsOneWidget);
      expect(find.textContaining('Bob'), findsOneWidget);
    });

    testWidgets('owner sees management actions for regular members', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob'),
        ]),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();

      expect(find.text('Transfer ownership'), findsOneWidget);
      expect(find.text('Remove from home'), findsOneWidget);
    });

    testWidgets('normal member does not see management actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob'),
        ], currentUserId: 'user-2'),
      );
      await tester.pump();

      expect(find.byTooltip('Member actions'), findsNothing);
    });

    testWidgets('current user cannot remove themselves', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob'),
        ]),
      );
      await tester.pump();

      expect(find.textContaining('You'), findsOneWidget);
      expect(find.byTooltip('Member actions'), findsOneWidget);
    });

    testWidgets('does not show remove action for another owner', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob', role: 'owner'),
        ]),
      );
      await tester.pump();

      expect(find.byTooltip('Member actions'), findsNothing);
    });

    testWidgets('shows transfer confirmation', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob'),
        ]),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer ownership'));
      await tester.pumpAndSettle();

      expect(find.text('Transfer ownership to Bob?'), findsOneWidget);
      expect(
        find.text(
          'They become the household owner. You become a regular member.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows remove confirmation', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
          makeMember(userId: 'user-2', displayName: 'Bob'),
        ]),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from home'));
      await tester.pumpAndSettle();

      expect(find.text('Remove Bob from this home?'), findsOneWidget);
      expect(
        find.text(
          'They lose access. Their historical activity remains, and they can join again later with an invite.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('successful remove refreshes members', (tester) async {
      var removed = false;
      var fetchCount = 0;
      final owner = makeMember(
        userId: 'user-1',
        displayName: 'Alice',
        role: 'owner',
      );
      final bob = makeMember(userId: 'user-2', displayName: 'Bob');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdMembersProvider('test-hh').overrideWith((ref) async {
              fetchCount++;
              return removed ? [owner] : [owner, bob];
            }),
          ],
          child: MaterialApp(
            home: MembersScreen(
              householdId: 'test-hh',
              currentUserIdOverride: 'user-1',
              removeMemberOverride: (householdId, userId) async {
                removed = true;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from home'));
      await tester.pumpAndSettle();

      expect(fetchCount, greaterThan(1));
      expect(find.text('Bob'), findsNothing);
      expect(find.text('Bob was removed.'), findsOneWidget);
    });

    testWidgets('remove action shows error and refreshes when it fails', (
      tester,
    ) async {
      var fetchCount = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdMembersProvider('test-hh').overrideWith((ref) async {
              fetchCount++;
              return [
                makeMember(
                  userId: 'user-1',
                  displayName: 'Alice',
                  role: 'owner',
                ),
                makeMember(userId: 'user-2', displayName: 'Bob'),
              ];
            }),
          ],
          child: MaterialApp(
            home: MembersScreen(
              householdId: 'test-hh',
              currentUserIdOverride: 'user-1',
              removeMemberOverride: (householdId, userId) async {
                throw StateError('changed');
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from home'));
      await tester.pumpAndSettle();

      expect(fetchCount, greaterThan(1));
      expect(find.text('Bob'), findsOneWidget);
      expect(
        find.text('Could not remove member. Please try again.'),
        findsOneWidget,
      );
    });

    testWidgets('successful transfer refreshes role display', (tester) async {
      var transferred = false;
      final aliceOwner = makeMember(
        userId: 'user-1',
        displayName: 'Alice',
        role: 'owner',
      );
      final aliceMember = makeMember(userId: 'user-1', displayName: 'Alice');
      final bobMember = makeMember(userId: 'user-2', displayName: 'Bob');
      final bobOwner = makeMember(
        userId: 'user-2',
        displayName: 'Bob',
        role: 'owner',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdMembersProvider('test-hh').overrideWith(
              (ref) async => transferred
                  ? [aliceMember, bobOwner]
                  : [aliceOwner, bobMember],
            ),
          ],
          child: MaterialApp(
            home: MembersScreen(
              householdId: 'test-hh',
              currentUserIdOverride: 'user-1',
              transferOwnershipOverride: (householdId, newOwnerId) async {
                transferred = true;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Member actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer ownership'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer ownership'));
      await tester.pumpAndSettle();

      expect(find.text('Ownership transferred.'), findsOneWidget);
      expect(find.byTooltip('Member actions'), findsNothing);
      expect(find.text('Owner'), findsOneWidget);
    });

    testWidgets('removed former member does not appear in active members UI', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
        ]),
      );
      await tester.pump();

      expect(find.text('Former member'), findsNothing);
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('shows empty state when no members', (tester) async {
      await tester.pumpWidget(buildMembersScreen([]));
      await tester.pump();
      expect(find.text('No members found.'), findsOneWidget);
    });

    testWidgets('sole owner household renders correctly', (tester) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
        ]),
      );
      await tester.pump();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Owner · You'), findsOneWidget);
    });

    testWidgets('renders 10 members without overflow', (tester) async {
      final members = [
        makeMember(userId: 'user-1', displayName: 'Alice', role: 'owner'),
        for (var i = 2; i <= 10; i++)
          makeMember(
            userId: 'user-$i',
            displayName: 'Member $i',
            publicId: 'member$i#0000',
          ),
      ];
      await tester.pumpWidget(buildMembersScreen(members));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Member 10'), 200);
      expect(find.text('Member 10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('long and non-Latin member names render without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildMembersScreen([
          makeMember(
            userId: 'user-1',
            displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
            role: 'owner',
          ),
          makeMember(
            userId: 'user-2',
            displayName: '田中 美咲 (Misaki Tanaka)',
            publicId: 'misaki#9999',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at 2.0x text scale without overflow', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2.0),
          ),
          child: buildMembersScreen([
            makeMember(
              userId: 'user-1',
              displayName: 'Christina Alexandra Okafor-Whitmore-Fitzgerald',
              role: 'owner',
            ),
            makeMember(userId: 'user-2', displayName: 'Bob'),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Household dashboard widget', () {
    testWidgets('list clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;

      double bottomPadding() {
        final listView = tester.widget<ListView>(find.byType(ListView));
        return (listView.padding! as EdgeInsets).bottom;
      }

      await tester.pumpWidget(buildDashboardScreen());
      await tester.pumpAndSettle();
      final withoutShell = bottomPadding();

      await tester.pumpWidget(buildDashboardScreen(navBarHeight: navBarHeight));
      await tester.pumpAndSettle();
      final withShell = bottomPadding();

      expect(withShell - withoutShell, navBarHeight);
    });

    testWidgets('shows summary counts and recent activity', (tester) async {
      await tester.pumpWidget(buildDashboardScreen());
      await tester.pump();

      expect(find.text('Test Home'), findsOneWidget);
      // Tasks/Shopping: hero number + descriptive sub-label, split apart.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('incomplete tasks'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('incomplete items'), findsOneWidget);
      // Expenses/Members: a quiet status line, no hero number.
      expect(find.text('5 expenses'), findsOneWidget);
      expect(find.text('4 active members'), findsOneWidget);
      expect(find.text('Statistics'), findsOneWidget);
      expect(find.text('View household statistics'), findsOneWidget);
      expect(find.text('Recent activity'), findsOneWidget);
      expect(find.text('View all activity'), findsOneWidget);
      expect(find.textContaining('Electricity'), findsOneWidget);
    });

    testWidgets('a subsection error does not hide Tasks/Shopping navigation', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdByIdProvider('test-hh').overrideWith(
              (ref) async => Household(
                id: 'test-hh',
                name: 'Test Home',
                createdBy: 'user-1',
                createdAt: DateTime.utc(2026, 8, 1),
              ),
            ),
            householdSummaryProvider(
              'test-hh',
            ).overrideWith((ref) async => _testSummary),
            householdInvitesProvider(
              'test-hh',
            ).overrideWith((ref) async => const []),
            householdRecentActivityProvider(
              'test-hh',
            ).overrideWith((ref) async => throw Exception('boom')),
          ],
          child: const MaterialApp(
            home: HouseholdDetailScreen(householdId: 'test-hh'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load activity.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      // Tasks/Shopping destinations are still there and tappable.
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
    });

    testWidgets('feature tiles do not overflow with a long household name', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdByIdProvider('test-hh').overrideWith(
              (ref) async => Household(
                id: 'test-hh',
                name:
                    'The Extended Family Household At The End Of The Long '
                    'Street With Many Members',
                createdBy: 'user-1',
                createdAt: DateTime.utc(2026, 8, 1),
              ),
            ),
            householdSummaryProvider(
              'test-hh',
            ).overrideWith((ref) async => _testSummary),
            householdInvitesProvider(
              'test-hh',
            ).overrideWith((ref) async => const []),
            householdRecentActivityProvider(
              'test-hh',
            ).overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            theme: appTheme,
            home: const HouseholdDetailScreen(householdId: 'test-hh'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('revoking an invite asks for confirmation first', (
      tester,
    ) async {
      final invite = HouseholdInvite(
        id: 'invite-1',
        householdId: 'test-hh',
        code: 'ABCD-EFGH',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 8, 1),
      );
      await tester.pumpWidget(buildDashboardScreen(invites: [invite]));
      await tester.pumpAndSettle();

      // The invites section sits below the fold on a typical test viewport;
      // scroll it into the ListView's built range first.
      await tester.scrollUntilVisible(find.text('ABCD-EFGH'), 200);
      await tester.tap(find.byTooltip('Revoke invite'));
      await tester.pumpAndSettle();

      // Names the action — never a generic "OK" — and the underlying revoke
      // call hasn't fired yet (this dialog has not been confirmed).
      expect(find.text('Revoke invite?'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Revoke'), findsOneWidget);
    });

    testWidgets('no active invite shows just the Invite member action', (
      tester,
    ) async {
      await tester.pumpWidget(buildDashboardScreen());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Invite member'), 200);
      expect(find.text('Invite member'), findsOneWidget);
      expect(find.byTooltip('Copy invite code'), findsNothing);
    });

    testWidgets('copying an invite code gives visible feedback', (
      tester,
    ) async {
      final invite = HouseholdInvite(
        id: 'invite-1',
        householdId: 'test-hh',
        code: 'ABCD-EFGH',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 8, 1),
      );
      await tester.pumpWidget(buildDashboardScreen(invites: [invite]));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('ABCD-EFGH'), 200);

      await tester.tap(find.byTooltip('Copy invite code'));
      await tester.pumpAndSettle();

      expect(find.text('Invite code copied'), findsOneWidget);
    });

    testWidgets('an invites load error does not hide dashboard navigation', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            householdByIdProvider('test-hh').overrideWith(
              (ref) async => Household(
                id: 'test-hh',
                name: 'Test Home',
                createdBy: 'user-1',
                createdAt: DateTime.utc(2026, 8, 1),
              ),
            ),
            householdSummaryProvider(
              'test-hh',
            ).overrideWith((ref) async => _testSummary),
            householdInvitesProvider(
              'test-hh',
            ).overrideWith((ref) async => throw Exception('boom')),
            householdRecentActivityProvider(
              'test-hh',
            ).overrideWith((ref) async => const []),
          ],
          child: const MaterialApp(
            home: HouseholdDetailScreen(householdId: 'test-hh'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Could not load invites.'),
        200,
      );
      expect(find.text('Could not load invites.'), findsOneWidget);
    });

    testWidgets('feature grid does not overflow at 1.3x text scale', (
      tester,
    ) async {
      // Wrap with larger text scale to catch fixed-height layout regressions.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      // All five feature tiles must still render without overflow.
      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Members'), findsOneWidget);
      expect(find.text('Statistics'), findsOneWidget);
      expect(find.text('View household statistics'), findsOneWidget);

      // No RenderFlex overflow error should be thrown.
      expect(tester.takeException(), isNull);
    });

    testWidgets('feature grid does not overflow at 2.0x text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2.0),
          ),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      expect(find.text('Tasks'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Members'), findsOneWidget);
      // At 2.0x scale, tiles correctly fall back to one column each (see the
      // Phase 1 breakpoint fix), so Statistics sits further down the list.
      await tester.scrollUntilVisible(find.text('Statistics'), 200);
      expect(find.text('Statistics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tile pairs are two-up at 339dp / 1.15x (current device)', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(339, 733));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(339, 733),
            textScaler: TextScaler.linear(1.15),
          ),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      final tasksRect = tileRectFor(tester, 'Tasks');
      final shoppingRect = tileRectFor(tester, 'Shopping');
      expect(tasksRect.top, shoppingRect.top);
      expect(tasksRect.left, isNot(shoppingRect.left));
      expect(tasksRect.width, closeTo(149.5, 1));
      expect(shoppingRect.width, closeTo(149.5, 1));

      final expensesRect = tileRectFor(tester, 'Expenses');
      final membersRect = tileRectFor(tester, 'Members');
      expect(expensesRect.top, membersRect.top);
      expect(expensesRect.left, isNot(membersRect.left));
      expect(expensesRect.width, closeTo(149.5, 1));
      expect(membersRect.width, closeTo(149.5, 1));

      expect(tester.takeException(), isNull);
    });

    testWidgets('tile pairs fall back to one column at 339dp / 2.0x', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(339, 733));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(339, 733),
            textScaler: TextScaler.linear(2.0),
          ),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      final tasksRect = tileRectFor(tester, 'Tasks');
      final shoppingRect = tileRectFor(tester, 'Shopping');
      expect(tasksRect.width, closeTo(307, 1));
      expect(shoppingRect.width, closeTo(307, 1));
      expect(tasksRect.left, closeTo(16, 1));
      expect(shoppingRect.left, closeTo(16, 1));
      expect(tasksRect.top, isNot(shoppingRect.top));

      expect(tester.takeException(), isNull);
    });

    testWidgets('tile pairs fall back to one column at 280dp / 1.0x', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(280, 653));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(280, 653),
            textScaler: TextScaler.linear(1.0),
          ),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      final tasksRect = tileRectFor(tester, 'Tasks');
      final shoppingRect = tileRectFor(tester, 'Shopping');
      expect(tasksRect.width, closeTo(248, 1));
      expect(shoppingRect.width, closeTo(248, 1));
      expect(tasksRect.top, isNot(shoppingRect.top));

      expect(tester.takeException(), isNull);
    });

    testWidgets('tile pairs are two-up at 412dp / 1.3x', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(412, 915),
            textScaler: TextScaler.linear(1.3),
          ),
          child: buildDashboardScreen(),
        ),
      );
      await tester.pump();

      final tasksRect = tileRectFor(tester, 'Tasks');
      final shoppingRect = tileRectFor(tester, 'Shopping');
      expect(tasksRect.top, shoppingRect.top);
      expect(tasksRect.left, isNot(shoppingRect.left));

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'dashboard regression: 339dp / 1.3x stays two-up with no overflow',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(339, 733));
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(339, 733),
              textScaler: TextScaler.linear(1.3),
            ),
            child: buildDashboardScreen(),
          ),
        );
        await tester.pump();

        final tasksRect = tileRectFor(tester, 'Tasks');
        final shoppingRect = tileRectFor(tester, 'Shopping');
        expect(tasksRect.top, shoppingRect.top);
        expect(tasksRect.left, isNot(shoppingRect.left));

        // Available width to the tile row is 339 - 32 (row padding) = 307;
        // tileWidth = (307 - 8) / 2 = 149.5. Neither tile may exceed its
        // allocated half.
        const tileWidth = 149.5;
        expect(tasksRect.width, lessThanOrEqualTo(tileWidth + 0.5));
        expect(shoppingRect.width, lessThanOrEqualTo(tileWidth + 0.5));

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('HouseholdSummary', () {
    test('holds correct counts', () {
      expect(_testSummary.incompleteTaskCount, 3);
      expect(_testSummary.incompleteShoppingCount, 2);
      expect(_testSummary.expenseCount, 5);
      expect(_testSummary.activeMemberCount, 4);
    });
  });
}
