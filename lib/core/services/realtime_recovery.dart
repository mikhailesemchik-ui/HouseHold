import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Bumped by the app shell every time the app returns to the foreground, so
/// streams that failed while the app was away can reopen straight away.
final realtimeResumeProvider = NotifierProvider<RealtimeResumeSignal, int>(
  RealtimeResumeSignal.new,
);

class RealtimeResumeSignal extends Notifier<int> {
  @override
  int build() => 0;

  void resumed() => state++;
}

/// Asks Supabase Auth for a new access token, whatever the local clock says.
/// A permanently rejected refresh token makes the SDK clear the session and
/// sign the user out (the app then returns to startup); a network failure
/// leaves the session untouched. Overridable so tests need no Supabase.
final sessionRefreshProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    await supabaseClient.auth.refreshSession();
  },
);

/// Whether PostgREST refused the access token itself (expired, or not valid
/// for this project). Only these are worth a refresh; a denial by row-level
/// security (42501) or any other error says nothing about the session.
bool isRejectedTokenError(Object error) =>
    error is PostgrestException &&
    (error.code == 'PGRST303' || error.code == 'PGRST301');

/// Wraps a Supabase `.stream()` so a transient Realtime failure heals itself.
///
/// supabase's stream builder reports a timed-out or errored channel as a plain
/// stream error, and after a failed Postgrest fetch it closes the stream for
/// good. A Riverpod provider then keeps showing that error forever. This
/// reopens the stream (a fresh channel AND a fresh snapshot) with a short,
/// bounded back-off. Transient errors are only logged: the UI keeps its data
/// and sees an error only once every retry has failed, and from then on the
/// next app resume tries again. A reply from the original stream before the
/// retry fires cancels the retry (the SDK recovered by itself).
///
/// Everything is tied to [ref]: when the provider is disposed (leaving the
/// screen, switching account) the timer and the subscription are cancelled and
/// no further open happens.
Stream<T> recoveringStream<T>(
  Ref ref,
  Stream<T> Function() open, {
  String label = 'stream',
  int maxRetries = 3,
  Duration retryDelay = const Duration(seconds: 2),
}) {
  final controller = StreamController<T>();
  StreamSubscription<T>? subscription;
  Timer? retryTimer;
  var attempts = 0;
  var hadError = false;
  var exhausted = false;
  var disposed = false;
  var refreshing = false;

  void start() {
    retryTimer?.cancel();
    retryTimer = null;
    subscription?.cancel().ignore();
    hadError = false;

    void onData(T value) {
      retryTimer?.cancel();
      retryTimer = null;
      attempts = 0;
      hadError = false;
      exhausted = false;
      if (!controller.isClosed) controller.add(value);
    }

    void scheduleRetry(Object error, StackTrace stackTrace) {
      if (disposed || retryTimer != null || exhausted) return;
      if (attempts >= maxRetries) {
        exhausted = true;
        if (!controller.isClosed) controller.addError(error, stackTrace);
        return;
      }
      attempts++;
      retryTimer = Timer(retryDelay * (1 << (attempts - 1)), start);
    }

    Future<void> refreshThenRetry(Object error, StackTrace stackTrace) async {
      refreshing = true;
      try {
        await ref.read(sessionRefreshProvider)();
      } catch (refreshError) {
        // Permanently rejected: the SDK has signed the user out and the app
        // returns to startup. Offline: the session is kept and the retry
        // below simply tries again.
        debugPrint('$label session refresh failed: $refreshError');
      } finally {
        refreshing = false;
      }
      if (!disposed) scheduleRetry(error, stackTrace);
    }

    void onError(Object error, StackTrace stackTrace) {
      hadError = true;
      debugPrint('$label realtime error (attempt $attempts): $error');
      if (!isRejectedTokenError(error)) {
        scheduleRetry(error, stackTrace);
      } else if (!refreshing && retryTimer == null && !exhausted) {
        // Reason: the SDK refreshes by its own clock, so a token the server
        // already considers expired can stay in use. Refresh explicitly
        // before reopening instead of retrying with the same dead token.
        if (attempts >= maxRetries) {
          scheduleRetry(error, stackTrace);
        } else {
          unawaited(refreshThenRetry(error, stackTrace));
        }
      }
    }

    void onDone() {
      if (disposed) return;
      if (hadError) {
        scheduleRetry(StateError('$label stream closed'), StackTrace.current);
      } else if (!controller.isClosed) {
        controller.close();
      }
    }

    try {
      subscription = open().listen(onData, onError: onError, onDone: onDone);
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }

  ref.listen<int>(realtimeResumeProvider, (previous, next) {
    if (disposed || !(exhausted || hadError)) return;
    attempts = 0;
    exhausted = false;
    start();
  });

  ref.onDispose(() {
    disposed = true;
    retryTimer?.cancel();
    subscription?.cancel().ignore();
    controller.close().ignore();
  });

  start();
  return controller.stream;
}
