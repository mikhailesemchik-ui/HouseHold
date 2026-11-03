import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/app/app.dart' show noProviderRetry;
import 'package:household_os/core/services/realtime_recovery.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

const _expiredJwt = PostgrestException(
  message: 'JWT expired',
  code: 'PGRST303',
  details: 'Unauthorized',
);

Future<void> _settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late _FakeSource source;
  late int refreshCalls;
  late Future<void> Function() refresh;
  late void Function(String?, {int? wrapWidth}) originalDebugPrint;

  setUp(() {
    source = _FakeSource();
    refreshCalls = 0;
    refresh = () async => refreshCalls++;
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
  });

  tearDown(() => debugPrint = originalDebugPrint);

  final provider = StreamProvider.autoDispose<List<String>>(
    (ref) => recoveringStream(
      ref,
      source.open,
      label: 'test',
      maxRetries: 3,
      retryDelay: const Duration(milliseconds: 5),
    ),
  );

  ProviderContainer start(List<AsyncValue<List<String>>> seen) {
    // Same as main.dart: the app turns Riverpod's own provider retries off.
    final container = ProviderContainer(
      retry: noProviderRetry,
      overrides: [sessionRefreshProvider.overrideWith((ref) => refresh)],
    );
    addTearDown(container.dispose);
    container.listen(provider, (_, next) => seen.add(next));
    return container;
  }

  test('an expired access token is refreshed, then the data resumes', () async {
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    // The SDK still thought the token valid (e.g. a device clock running
    // behind), so only the server noticed it had expired.
    source.latest.addError(_expiredJwt);
    await _settle();

    expect(refreshCalls, 1, reason: 'the session is refreshed explicitly');
    expect(source.opened.length, 2, reason: 'a fresh stream after the refresh');
    source.latest.add(['task']);
    await _settle();
    expect(seen.last.value, ['task']);
    expect(seen.any((v) => v.hasError), isFalse);
  });

  test('a rejected (invalid) token also triggers one refresh', () async {
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    source.latest.addError(
      const PostgrestException(message: 'No suitable key', code: 'PGRST301'),
    );
    await _settle();

    expect(refreshCalls, 1);
    expect(source.opened.length, 2);
  });

  test('a refresh the server rejects for good does not loop forever', () async {
    refresh = () async {
      refreshCalls++;
      // gotrue has already cleared the session and signed the user out by
      // the time this is thrown; the app only has to stop retrying.
      throw const AuthApiException(
        'Invalid Refresh Token',
        statusCode: '400',
        code: 'refresh_token_not_found',
      );
    };
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    for (var i = 0; i < 8; i++) {
      source.latest.addError(_expiredJwt);
      await _settle();
    }

    expect(refreshCalls, lessThanOrEqualTo(3), reason: 'bounded by retries');
    expect(source.opened.length, lessThanOrEqualTo(4));
    expect(seen.last.hasError, isTrue, reason: 'the failure is surfaced');
  });

  test('a network failure while refreshing keeps retrying, never gives up '
      'the session', () async {
    var online = false;
    refresh = () async {
      refreshCalls++;
      if (!online) {
        throw AuthRetryableFetchException(message: 'offline');
      }
    };
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    source.latest.addError(_expiredJwt);
    await _settle();
    expect(source.opened.length, 2, reason: 'still retried while offline');

    online = true;
    source.latest.addError(_expiredJwt);
    await _settle();
    source.latest.add(['back']);
    await _settle();

    expect(seen.last.value, ['back']);
  });

  test('an unrelated denial (RLS) does not touch the session', () async {
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    source.latest.addError(
      const PostgrestException(
        message: 'permission denied for table tasks',
        code: '42501',
      ),
    );
    await _settle();

    expect(refreshCalls, 0);
    expect(source.opened.length, 2, reason: 'normal transient retry');
  });

  test('a burst of rejected-token errors refreshes only once', () async {
    final gate = Completer<void>();
    refresh = () async {
      refreshCalls++;
      await gate.future;
    };
    final seen = <AsyncValue<List<String>>>[];
    start(seen);

    final first = source.latest;
    first.addError(_expiredJwt);
    first.addError(_expiredJwt);
    await _settle();
    gate.complete();
    await _settle();

    expect(refreshCalls, 1);
  });
}
