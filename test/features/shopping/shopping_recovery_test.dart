import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/realtime_recovery.dart';
import 'package:household_os/features/shopping/domain/shopping_item.dart';
import 'package:household_os/features/shopping/presentation/shopping_provider.dart';
import 'package:household_os/features/shopping/presentation/shopping_screen.dart';

ShoppingItem _item(String name) {
  final ts = DateTime.utc(2026, 8, 27, 10);
  return ShoppingItem(
    id: name,
    householdId: 'hh',
    name: name,
    createdBy: 'u',
    createdAt: ts,
    updatedAt: ts,
  );
}

/// The real Shopping screen driven through the real [recoveringStream], with
/// the Supabase stream replaced by connections the test can feed and break.
void main() {
  late List<StreamController<List<ShoppingItem>>> connections;
  late ProviderContainer container;

  Future<void> pumpShopping(WidgetTester tester, {int maxRetries = 3}) async {
    connections = [];
    container = ProviderContainer(
      overrides: [
        shoppingItemsProvider('hh').overrideWith(
          (ref) => recoveringStream(
            ref,
            () {
              final c = StreamController<List<ShoppingItem>>();
              connections.add(c);
              return c.stream;
            },
            label: 'shopping',
            maxRetries: maxRetries,
            retryDelay: const Duration(milliseconds: 50),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: appTheme,
          home: const ShoppingScreen(householdId: 'hh'),
        ),
      ),
    );
    await tester.pump();
  }

  const errorText = 'Could not load shopping list. Please try again.';

  testWidgets('a transient timeout never reaches the screen and fresh data '
      'appears without navigating', (tester) async {
    await pumpShopping(tester);
    connections.last.add([_item('Milk')]);
    await tester.pump();
    expect(find.text('Milk'), findsOneWidget);

    connections.last.addError(StateError('timedOut'));
    await tester.pump();
    expect(find.text(errorText), findsNothing);
    expect(find.text('Milk'), findsOneWidget, reason: 'data stays on screen');

    await tester.pump(const Duration(milliseconds: 60));
    expect(connections.length, 2, reason: 'a fresh connection was opened');
    connections.last.add([_item('Milk'), _item('Oat milk')]);
    await tester.pump();
    expect(find.text('Oat milk'), findsOneWidget);
    expect(find.text(errorText), findsNothing);
  });

  testWidgets('after the retries are used up the error is shown, and the '
      'next app resume recovers the screen', (tester) async {
    await pumpShopping(tester, maxRetries: 1);

    connections.last.addError(StateError('down'));
    await tester.pump(const Duration(milliseconds: 60));
    connections.last.addError(StateError('still down'));
    await tester.pump();
    expect(find.text(errorText), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget, reason: 'actionable error');
    final opensWhenFailed = connections.length;
    await tester.pump(const Duration(seconds: 1));
    expect(connections.length, opensWhenFailed, reason: 'no retry storm');

    container.read(realtimeResumeProvider.notifier).resumed();
    await tester.pump();
    expect(connections.length, opensWhenFailed + 1);
    connections.last.add([_item('Bread')]);
    await tester.pumpAndSettle();
    expect(find.text('Bread'), findsOneWidget);
    expect(find.text(errorText), findsNothing);
  });

  testWidgets('tearing the scope down (account switch) cancels a pending '
      'retry and the connection', (tester) async {
    await pumpShopping(tester);
    connections.last.addError(StateError('timedOut'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 1));

    expect(connections.length, 1, reason: 'no reopen after the scope is gone');
    expect(connections.any((c) => c.hasListener), isFalse);
  });
}
