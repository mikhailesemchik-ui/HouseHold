import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/app/routing/app_router.dart';
import 'package:household_os/app/user_scoped_root.dart';

/// Stands in for everything user-scoped: cached data, a Realtime-style stream,
/// and a slow mutation.
final _cachedDataProvider = NotifierProvider<_Cached, String>(_Cached.new);
final streamCancelled = <String>[];

class _Cached extends Notifier<String> {
  @override
  String build() => 'empty';

  void load(String value) => state = value;

  /// A mutation started by the old user that finishes later.
  Future<void> commitLater(Future<void> gate, String value) async {
    await gate;
    if (ref.mounted) state = value;
  }
}

final _streamProvider = StreamProvider<int>((ref) {
  final controller = StreamController<int>(
    onCancel: () => streamCancelled.add('cancelled'),
  );
  ref.onDispose(controller.close);
  return controller.stream;
});

class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_streamProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(ref.watch(_cachedDataProvider)),
    );
  }
}

class _Rig {
  _Rig(this.initial);

  final String? initial;
  final ids = StreamController<String?>.broadcast();
  int userChanges = 0;

  Widget get widget => UserScopedRoot(
    initialUserId: initial,
    userIdChanges: ids.stream,
    onUserChanged: () => userChanges++,
    child: const _Probe(),
  );

  /// Emits an auth event and lets the root react: the event is delivered in a
  /// microtask, then the rebuilt tree needs a frame.
  Future<void> emit(WidgetTester tester, String? id) async {
    ids.add(id);
    await tester.pump();
    await tester.pump();
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(_Probe)));
}

void main() {
  setUp(streamCancelled.clear);

  testWidgets(
    'a token refresh or repeated event for the same user keeps state',
    (tester) async {
      final rig = _Rig('user-a');
      await tester.pumpWidget(rig.widget);
      rig.container(tester).read(_cachedDataProvider.notifier).load('A data');
      await tester.pump();
      expect(find.text('A data'), findsOneWidget);

      rig.ids.add('user-a'); // tokenRefreshed / userUpdated carry the same id
      await rig.emit(tester, 'user-a');
      expect(find.text('A data'), findsOneWidget);
      expect(rig.userChanges, 0);
      expect(streamCancelled, isEmpty);
    },
  );

  testWidgets('another user gets a fresh scope: A\'s data is gone in the very '
      'next frame and A\'s stream is cancelled', (tester) async {
    final rig = _Rig('user-a');
    await tester.pumpWidget(rig.widget);
    rig.container(tester).read(_cachedDataProvider.notifier).load('A data');
    await tester.pump();

    await rig.emit(tester, 'user-b');
    expect(find.text('A data'), findsNothing);
    expect(find.text('empty'), findsOneWidget);
    expect(rig.userChanges, 1);
    expect(streamCancelled, ['cancelled'], reason: 'old stream stopped');
  });

  testWidgets('signing out and in again also starts clean', (tester) async {
    final rig = _Rig('user-a');
    await tester.pumpWidget(rig.widget);
    rig.container(tester).read(_cachedDataProvider.notifier).load('A data');
    await tester.pump();

    await rig.emit(tester, null);
    expect(find.text('empty'), findsOneWidget);
    await rig.emit(tester, 'user-a');
    expect(find.text('A data'), findsNothing);
    expect(rig.userChanges, 2);
  });

  testWidgets('a mutation that finishes after the switch cannot change the '
      'new user\'s state', (tester) async {
    final rig = _Rig('user-a');
    await tester.pumpWidget(rig.widget);
    final gate = Completer<void>();
    final pending = rig
        .container(tester)
        .read(_cachedDataProvider.notifier)
        .commitLater(gate.future, 'A late write');

    await rig.emit(tester, 'user-b');
    gate.complete();
    await pending;
    await tester.pump();

    expect(find.text('A late write'), findsNothing);
    expect(rig.container(tester).read(_cachedDataProvider), 'empty');
  });

  testWidgets('with no session at launch, the first user replaces the scope', (
    tester,
  ) async {
    final rig = _Rig(null);
    await tester.pumpWidget(rig.widget);
    rig.container(tester).read(_cachedDataProvider.notifier).load('guest');
    await tester.pump();

    await rig.emit(tester, 'user-a');
    expect(find.text('guest'), findsNothing);
    expect(rig.userChanges, 1);
  });

  testWidgets("the previous user's household route does not survive a user "
      'change (the selection lives in the route)', (tester) async {
    final router = GoRouter(
      initialLocation: '/homes/household-of-a',
      routes: [
        GoRoute(
          path: '/startup',
          builder: (_, _) =>
              const Text('STARTUP', textDirection: TextDirection.ltr),
        ),
        GoRoute(
          path: '/homes/:id',
          builder: (_, state) => Text(
            'HOME ${state.pathParameters['id']}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );
    final ids = StreamController<String?>.broadcast();
    await tester.pumpWidget(
      UserScopedRoot(
        initialUserId: 'user-a',
        userIdChanges: ids.stream,
        onUserChanged: () => router.go('/startup'),
        child: Builder(
          builder: (_) => MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('HOME household-of-a'), findsOneWidget);

    ids.add('user-b');
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('HOME household-of-a'), findsNothing);
    expect(find.text('STARTUP'), findsOneWidget);
    await ids.close();
  });

  group('session redirect', () {
    test('startup and recovery are always reachable', () {
      for (final hasSession in [true, false]) {
        expect(sessionRedirect('/startup', hasSession: hasSession), isNull);
        expect(sessionRedirect('/recover', hasSession: hasSession), isNull);
      }
    });

    test('without a session every app route returns to startup', () {
      for (final path in ['/today', '/homes', '/homes/h1/tasks', '/profile']) {
        expect(sessionRedirect(path, hasSession: false), '/startup');
        expect(sessionRedirect(path, hasSession: true), isNull);
      }
    });
  });
}
