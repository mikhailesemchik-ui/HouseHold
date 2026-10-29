import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/realtime_recovery.dart';

/// A stand-in for a Supabase stream: every call to [open] is a fresh
/// connection the test can feed or break.
class _FakeSource {
  final opened = <StreamController<List<String>>>[];

  Stream<List<String>> open() {
    final c = StreamController<List<String>>();
    opened.add(c);
    return c.stream;
  }

  StreamController<List<String>> get latest => opened.last;
}

const _tick = Duration(milliseconds: 60);

Future<void> _settle([Duration d = _tick]) => Future<void>.delayed(d);

void main() {
  late _FakeSource source;
  late List<String> logs;
  late void Function(String?, {int? wrapWidth}) originalDebugPrint;

  setUp(() {
    source = _FakeSource();
    logs = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  StreamProvider<List<String>> providerFor({
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 5),
  }) => StreamProvider.autoDispose<List<String>>(
    (ref) => recoveringStream(
      ref,
      source.open,
      label: 'test',
      maxRetries: maxRetries,
      retryDelay: retryDelay,
    ),
  );

  ProviderContainer containerWith(
    StreamProvider<List<String>> provider,
    List<AsyncValue<List<String>>> seen,
  ) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(
      provider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    return container;
  }

  test(
    'R1 a timed-out subscription is reopened and the data comes back',
    () async {
      final provider = providerFor();
      final seen = <AsyncValue<List<String>>>[];
      final container = containerWith(provider, seen);

      source.latest.add(['a']);
      await _settle();
      source.latest.addError(StateError('timedOut'));
      await _settle();

      expect(source.opened.length, 2, reason: 'a fresh stream (and snapshot)');
      expect(
        seen.any((v) => v.hasError && !v.hasValue),
        isFalse,
        reason: 'a transient error must not replace the screen with an error',
      );
      source.latest.add(['a', 'b']);
      await _settle();
      expect(container.read(provider).value, ['a', 'b']);
      expect(container.read(provider).hasError, isFalse);
      expect(logs.any((l) => l.contains('test realtime error')), isTrue);
    },
  );

  test('R2 a stream the SDK closes after an error is reopened', () async {
    final provider = providerFor();
    final seen = <AsyncValue<List<String>>>[];
    final container = containerWith(provider, seen);

    source.latest.addError(StateError('JWT expired'));
    await source.latest.close();
    await _settle();

    expect(source.opened.length, 2);
    source.latest.add(['fresh']);
    await _settle();
    expect(container.read(provider).value, ['fresh']);
  });

  test('a stream that ends normally is not reopened', () async {
    final provider = providerFor();
    final container = containerWith(provider, []);

    source.latest.add(['a']);
    await source.latest.close();
    await _settle();

    expect(source.opened.length, 1);
    expect(container.read(provider).value, ['a']);
  });

  test('the original stream recovering by itself cancels the retry', () async {
    final provider = providerFor(retryDelay: const Duration(milliseconds: 80));
    final container = containerWith(provider, []);

    source.latest.addError(StateError('channelError'));
    await _settle(const Duration(milliseconds: 10));
    source.latest.add(['healed']);
    await _settle(const Duration(milliseconds: 150));

    expect(source.opened.length, 1, reason: 'no redundant reopen');
    expect(container.read(provider).value, ['healed']);
  });

  test('R7 a persistent outage retries a bounded number of times, then shows '
      'the error', () async {
    final provider = providerFor(maxRetries: 2);
    final seen = <AsyncValue<List<String>>>[];
    final container = containerWith(provider, seen);

    for (var i = 0; i < 3; i++) {
      source.latest.addError(StateError('down $i'));
      await _settle();
    }
    await _settle(const Duration(milliseconds: 200));

    expect(source.opened.length, 3, reason: '1 open + 2 retries, no more');
    expect(container.read(provider).hasError, isTrue);
  });

  test('R3 resuming reopens a stream that gave up, and data returns', () async {
    final provider = providerFor(maxRetries: 1);
    final container = containerWith(provider, []);

    for (var i = 0; i < 2; i++) {
      source.latest.addError(StateError('asleep'));
      await _settle();
    }
    expect(container.read(provider).hasError, isTrue);
    expect(source.opened.length, 2);

    container.read(realtimeResumeProvider.notifier).resumed();
    await _settle();
    expect(source.opened.length, 3);
    source.latest.add(['after resume']);
    await _settle();
    expect(container.read(provider).value, ['after resume']);
    expect(container.read(provider).hasError, isFalse);
  });

  test('R4 and R5 updates after recovery arrive once; resumes on a healthy '
      'stream open nothing', () async {
    final provider = providerFor();
    final emitted = <List<String>>[];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(provider, (_, next) {
      final v = next.value;
      if (v != null) emitted.add(v);
    }, fireImmediately: true);

    source.latest.add(['1']);
    source.latest.addError(StateError('x'));
    await _settle();
    source.latest.add(['1', '2']);
    await _settle();
    final opensBefore = source.opened.length;

    for (var i = 0; i < 3; i++) {
      container.read(realtimeResumeProvider.notifier).resumed();
    }
    await _settle();

    expect(source.opened.length, opensBefore, reason: 'healthy: no reopen');
    expect(emitted, [
      ['1'],
      ['1', '2'],
    ]);
    // Only the newest connection is listened to.
    expect(
      source.opened.where((c) => c.hasListener).length,
      1,
      reason: 'older connections are cancelled, never duplicated',
    );
  });

  test(
    'R5 and R6 disposing the provider cancels the stream and any retry',
    () async {
      final provider = providerFor(
        retryDelay: const Duration(milliseconds: 40),
      );
      final container = ProviderContainer();
      final sub = container.listen(provider, (_, _) {});

      source.latest.addError(StateError('about to retry'));
      await _settle(const Duration(milliseconds: 5));
      sub.close();
      container.dispose();
      await _settle(const Duration(milliseconds: 120));

      expect(source.opened.length, 1, reason: 'no retry after disposal');
      expect(source.opened.any((c) => c.hasListener), isFalse);
    },
  );

  test(
    'R6 a new container (another account) never sees the old data',
    () async {
      final provider = providerFor();
      final first = ProviderContainer();
      first.listen(provider, (_, _) {});
      source.latest.add(['old account data']);
      await _settle();
      expect(first.read(provider).value, ['old account data']);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.listen(provider, (_, _) {});
      expect(second.read(provider).value, isNull);
      source.latest.add(['new account data']);
      await _settle();
      expect(second.read(provider).value, ['new account data']);
    },
  );

  test('a failure while opening is handled like any other error', () async {
    var calls = 0;
    final provider = StreamProvider.autoDispose<int>(
      (ref) => recoveringStream<int>(ref, () {
        calls++;
        if (calls == 1) throw StateError('client not ready');
        return Stream.value(7);
      }, retryDelay: const Duration(milliseconds: 5)),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(provider, (_, _) {});
    await _settle();

    expect(calls, 2);
    expect(container.read(provider).value, 7);
  });
}
