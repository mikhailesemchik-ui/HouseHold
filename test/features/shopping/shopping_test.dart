import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/features/shopping/data/shopping_repository.dart';
import 'package:household_os/features/shopping/domain/shopping_item.dart';
import 'package:household_os/features/shopping/presentation/shopping_provider.dart';
import 'package:household_os/features/shopping/presentation/shopping_screen.dart';

ShoppingItem makeItem({
  String id = 'item-1',
  String name = 'Milk',
  String? quantity,
  DateTime? completedAt,
  String? completedBy,
  DateTime? createdAt,
}) {
  final ts = createdAt ?? DateTime.utc(2026, 8, 27, 10);
  return ShoppingItem(
    id: id,
    householdId: 'hh-1',
    name: name,
    quantity: quantity,
    createdBy: 'user-1',
    createdAt: ts,
    updatedAt: ts,
    completedAt: completedAt,
    completedBy: completedBy,
  );
}

/// [navBarHeight] wraps the screen in a stand-in for the app shell — the same
/// `Scaffold(extendBody: true)` + bottom navigation arrangement that publishes
/// the nav bar's measured height as `MediaQuery.padding.bottom`.
Widget buildScreen(Stream<List<ShoppingItem>> stream, {double? navBarHeight}) {
  const screen = ShoppingScreen(householdId: 'test-hh');
  return ProviderScope(
    overrides: [shoppingItemsProvider('test-hh').overrideWith((ref) => stream)],
    child: MaterialApp(
      theme: appTheme,
      home: navBarHeight == null
          ? screen
          : Scaffold(
              extendBody: true,
              bottomNavigationBar: SizedBox(height: navBarHeight),
              body: screen,
            ),
    ),
  );
}

void main() {
  // ---------------------------------------------------------------------------
  group('ShoppingItem.fromMap', () {
    final baseMap = {
      'id': 'abc',
      'household_id': 'hh-1',
      'name': 'Bread',
      'quantity': null,
      'created_by': 'user-1',
      'created_at': '2026-08-27T10:00:00.000Z',
      'updated_at': '2026-08-27T10:00:00.000Z',
      'completed_at': null,
      'completed_by': null,
    };

    test('parses an incomplete item', () {
      final item = ShoppingItem.fromMap(baseMap);
      expect(item.id, 'abc');
      expect(item.name, 'Bread');
      expect(item.quantity, isNull);
      expect(item.isCompleted, isFalse);
      expect(item.completedAt, isNull);
      expect(item.completedBy, isNull);
    });

    test('parses a completed item', () {
      final map = {
        ...baseMap,
        'completed_at': '2026-08-27T14:00:00.000Z',
        'completed_by': 'user-2',
      };
      final item = ShoppingItem.fromMap(map);
      expect(item.isCompleted, isTrue);
      expect(item.completedAt, isNotNull);
      expect(item.completedBy, 'user-2');
    });

    test('parses quantity correctly', () {
      final map = {...baseMap, 'quantity': '2 kg'};
      final item = ShoppingItem.fromMap(map);
      expect(item.quantity, '2 kg');
    });

    test('isCompleted is false when completedAt is null', () {
      final item = makeItem();
      expect(item.isCompleted, isFalse);
    });

    test('isCompleted is true when completedAt is set', () {
      final item = makeItem(
        completedAt: DateTime.utc(2026, 8, 27, 14),
        completedBy: 'user-2',
      );
      expect(item.isCompleted, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('ShoppingRepository.validateName', () {
    test('returns null for a valid name', () {
      expect(ShoppingRepository.validateName('Milk'), isNull);
    });

    test('returns error for empty string', () {
      expect(ShoppingRepository.validateName(''), isNotNull);
    });

    test('returns error for whitespace-only string', () {
      expect(ShoppingRepository.validateName('   '), isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('ordering', () {
    List<ShoppingItem> sorted(List<ShoppingItem> items) {
      final copy = [...items];
      copy.sort((a, b) {
        if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
        if (!a.isCompleted) return b.createdAt.compareTo(a.createdAt);
        return a.completedAt!.compareTo(b.completedAt!);
      });
      return copy;
    }

    test('incomplete items appear before completed', () {
      final items = [
        makeItem(
          id: '1',
          completedAt: DateTime.utc(2026, 8, 27, 12),
          completedBy: 'u',
        ),
        makeItem(id: '2'),
      ];
      final result = sorted(items);
      expect(result.first.id, '2');
      expect(result.last.id, '1');
    });

    test('incomplete items sorted newest first', () {
      final items = [
        makeItem(id: 'old', createdAt: DateTime.utc(2026, 8, 27, 8)),
        makeItem(id: 'new', createdAt: DateTime.utc(2026, 8, 27, 12)),
      ];
      final result = sorted(items);
      expect(result.first.id, 'new');
      expect(result.last.id, 'old');
    });

    test('completed items sorted by completedAt ascending', () {
      final items = [
        makeItem(
          id: 'later',
          completedAt: DateTime.utc(2026, 8, 27, 15),
          completedBy: 'u',
        ),
        makeItem(
          id: 'earlier',
          completedAt: DateTime.utc(2026, 8, 27, 11),
          completedBy: 'u',
        ),
      ];
      final result = sorted(items);
      expect(result.first.id, 'earlier');
      expect(result.last.id, 'later');
    });
  });

  // ---------------------------------------------------------------------------
  group('ShoppingScreen widget', () {
    testWidgets('shows empty state with composer still reachable', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen(Stream.value([])));
      await tester.pumpAndSettle();
      expect(find.text('Nothing on the list.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('empty state has no illustration icon', (tester) async {
      await tester.pumpWidget(buildScreen(Stream.value([])));
      await tester.pumpAndSettle();
      final emptyState = find.byType(AppEmptyState);
      expect(emptyState, findsOneWidget);
      expect(
        find.descendant(of: emptyState, matching: find.byType(Icon)),
        findsNothing,
      );
    });

    testWidgets('shows item name in list', (tester) async {
      final items = [makeItem(name: 'Orange juice')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      expect(find.text('Orange juice'), findsOneWidget);
    });

    testWidgets('shows quantity as subtitle', (tester) async {
      final items = [makeItem(name: 'Flour', quantity: '1 kg')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      expect(find.text('1 kg'), findsOneWidget);
    });

    testWidgets('completed item renders with strikethrough', (tester) async {
      final items = [
        makeItem(
          name: 'Done item',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      final text = tester.widget<Text>(find.text('Done item'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('incomplete item has no strikethrough', (tester) async {
      final items = [makeItem(name: 'Active item')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      final text = tester.widget<Text>(find.text('Active item'));
      // decoration may be null or none — not lineThrough
      expect(text.style?.decoration, isNot(TextDecoration.lineThrough));
    });

    testWidgets('clear completed button shown when completed items exist', (
      tester,
    ) async {
      final items = [
        makeItem(
          id: '1',
          name: 'Done',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      expect(find.text('Clear completed'), findsOneWidget);
    });

    testWidgets('clear completed button not shown with no completed items', (
      tester,
    ) async {
      final items = [makeItem(name: 'Active')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      expect(find.text('Clear completed'), findsNothing);
    });

    testWidgets('clear completed shows confirmation dialog', (tester) async {
      final items = [
        makeItem(
          id: '1',
          name: 'Done',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      await tester.tap(find.text('Clear completed'));
      await tester.pump();
      expect(find.text('Clear completed items?'), findsOneWidget);
    });

    testWidgets('fast-add field is present', (tester) async {
      await tester.pumpWidget(buildScreen(Stream.value([])));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows real screen shell with local loading while pending', (
      tester,
    ) async {
      final controller = StreamController<List<ShoppingItem>>();
      addTearDown(controller.close);
      await tester.pumpWidget(buildScreen(controller.stream));
      await tester.pump();
      expect(find.text('Shopping'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // FUNC-001 regression: the actual bug lives in Postgres/Realtime config
    // (a filtered DELETE subscription silently drops events without
    // `REPLICA IDENTITY FULL` — see the shopping_items migration), which
    // cannot be reproduced by a widget test since no real Postgres/Realtime
    // server is involved here. What CAN be verified deterministically at
    // this layer is the consumer side: if the stream ever does emit an
    // updated list reflecting a reopen or a delete — which is exactly what
    // a correct realtime delivery looks like once the migration is applied
    // — the screen must re-section/remove the item on that same emission,
    // with no stale rendering of its own. This guards the one part of the
    // pipeline actually reachable from Flutter tests.
    testWidgets(
      'reopening then deleting a completed item on the same live stream '
      'updates the screen on each emission',
      (tester) async {
        final controller = StreamController<List<ShoppingItem>>();
        addTearDown(controller.close);
        await tester.pumpWidget(buildScreen(controller.stream));

        final completedItem = makeItem(
          id: '1',
          name: 'QA Shopping Item',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        );
        controller.add([completedItem]);
        await tester.pump();
        expect(find.text('Completed · 1'), findsOneWidget);
        final completedText = tester.widget<Text>(
          find.text('QA Shopping Item'),
        );
        expect(completedText.style?.decoration, TextDecoration.lineThrough);

        // Reopen: same id, completedAt/completedBy now null — mirrors what
        // `reopenItem`'s UPDATE produces once realtime delivers it.
        final reopenedItem = makeItem(id: '1', name: 'QA Shopping Item');
        controller.add([reopenedItem]);
        await tester.pump();
        expect(find.text('Completed · 1'), findsNothing);
        final reopenedText = tester.widget<Text>(find.text('QA Shopping Item'));
        expect(
          reopenedText.style?.decoration,
          isNot(TextDecoration.lineThrough),
        );

        // Delete: mirrors what `deleteItem`'s DELETE produces once realtime
        // delivers it — the row simply stops appearing in the emitted list.
        controller.add(const []);
        await tester.pump();
        expect(find.text('QA Shopping Item'), findsNothing);
        expect(find.text('Nothing on the list.'), findsOneWidget);
      },
    );

    testWidgets('multiple items all render', (tester) async {
      final items = [
        makeItem(id: '1', name: 'Apples'),
        makeItem(id: '2', name: 'Bananas'),
        makeItem(id: '3', name: 'Carrots'),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pump();
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('Bananas'), findsOneWidget);
      expect(find.text('Carrots'), findsOneWidget);
    });

    testWidgets('active items render without Card wrappers', (tester) async {
      final items = [makeItem(id: '1', name: 'Apples')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('completed items render under a Completed section header', (
      tester,
    ) async {
      final items = [
        makeItem(id: '1', name: 'Active'),
        makeItem(
          id: '2',
          name: 'Done',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pumpAndSettle();
      expect(find.text('Completed · 1'), findsOneWidget);
    });

    testWidgets('completion control describes the item by name', (
      tester,
    ) async {
      final items = [makeItem(id: '1', name: 'Milk')];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mark "Milk" as done'), findsOneWidget);
    });

    testWidgets('long item name does not overflow', (tester) async {
      final items = [
        makeItem(
          id: '1',
          name:
              'Organic whole-grain sourdough bread from the bakery on the '
              'corner near the old train station',
        ),
      ];
      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Organic whole-grain'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('composer preserves entered text when the mutation fails', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen(Stream.value([])));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Milk');
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      // No Supabase client is initialized in this test, so the mutation
      // fails — the composer must not silently discard what was typed.
      expect(find.text('Milk'), findsOneWidget);
    });

    testWidgets('list clears the shell navigation exactly once', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      final items = [makeItem(id: '1', name: 'Apples')];

      double bottomPadding() {
        final listView = tester.widget<ListView>(find.byType(ListView));
        return (listView.padding! as EdgeInsets).bottom;
      }

      await tester.pumpWidget(buildScreen(Stream.value(items)));
      await tester.pumpAndSettle();
      final withoutShell = bottomPadding();

      await tester.pumpWidget(
        buildScreen(Stream.value(items), navBarHeight: navBarHeight),
      );
      await tester.pumpAndSettle();
      final withShell = bottomPadding();

      // Introducing the shell's navigation must add its height to the list's
      // clearance exactly once. The previous convention added it twice (the
      // measured MediaQuery inset plus a hand-maintained constant).
      expect(withShell - withoutShell, navBarHeight);
      // The composer's own clearance is present in both cases.
      expect(withoutShell, greaterThan(0));
    });

    testWidgets('resting composer sits above the shell navigation', (
      tester,
    ) async {
      const navBarHeight = 64.0;
      await tester.pumpWidget(
        buildScreen(Stream.value([]), navBarHeight: navBarHeight),
      );
      await tester.pumpAndSettle();

      final positioned = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byType(TextField),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(positioned.bottom, greaterThanOrEqualTo(navBarHeight));
      // Guards the double count: one nav height plus a small gap, not two.
      expect(positioned.bottom, lessThan(navBarHeight * 2));
    });

    testWidgets(
      'composer anchors to the viewport bottom when focused, not the resting nav offset',
      (tester) async {
        // Needs the shell, because that is what gives the resting composer a
        // nav bar to sit above in the first place.
        await tester.pumpWidget(
          buildScreen(Stream.value([]), navBarHeight: 64),
        );
        await tester.pumpAndSettle();

        Positioned composerPositioned() => tester.widget<Positioned>(
          find
              .ancestor(
                of: find.byType(TextField),
                matching: find.byType(Positioned),
              )
              .first,
        );

        final restingBottom = composerPositioned().bottom!;

        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();

        final focusedBottom = composerPositioned().bottom!;
        expect(focusedBottom, lessThan(restingBottom));
      },
    );

    testWidgets(
      'composer position movement is immediate when animations are disabled',
      (tester) async {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: buildScreen(Stream.value([]), navBarHeight: 64),
          ),
        );
        await tester.pumpAndSettle();

        AnimatedPositioned composerAnimatedPositioned() =>
            tester.widget<AnimatedPositioned>(
              find
                  .ancestor(
                    of: find.byType(TextField),
                    matching: find.byType(AnimatedPositioned),
                  )
                  .first,
            );

        expect(composerAnimatedPositioned().duration, Duration.zero);

        await tester.tap(find.byType(TextField));
        // A single pump (not pumpAndSettle) is enough: with a zero duration
        // the position change lands on the very next frame rather than over
        // an animated series of frames.
        await tester.pump();

        final positioned = tester.widget<Positioned>(
          find
              .ancestor(
                of: find.byType(TextField),
                matching: find.byType(Positioned),
              )
              .first,
        );
        expect(positioned.bottom, AppSpacing.sm);
      },
    );

    testWidgets('large text scale renders without overflow', (tester) async {
      final items = [
        makeItem(id: '1', name: 'Apples'),
        makeItem(
          id: '2',
          name: 'Done',
          quantity: '2 kg',
          completedAt: DateTime.utc(2026, 8, 27, 14),
          completedBy: 'u',
        ),
      ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: buildScreen(Stream.value(items)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
