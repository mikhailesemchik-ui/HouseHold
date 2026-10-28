import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';

/// What the recovery flow needs: ask for a code and check one. The real
/// implementation uses the F1 repository (always `shouldCreateUser: false`)
/// and the session-switch coordinator; neither can create an account or sign
/// in anonymously.
abstract interface class RecoveryActions {
  Future<void> requestCode(String email);

  Future<AuthIdentity> verify(String email, String code);
}

final recoveryActionsProvider = Provider<RecoveryActions>((ref) {
  return _SupabaseRecoveryActions(ref);
});

class _SupabaseRecoveryActions implements RecoveryActions {
  _SupabaseRecoveryActions(this._ref);

  final Ref _ref;

  @override
  Future<void> requestCode(String email) {
    return _ref.read(emailAccountRepositoryProvider).sendRecoveryCode(email);
  }

  @override
  Future<AuthIdentity> verify(String email, String code) async {
    final coordinator = await _ref.read(
      sessionSwitchCoordinatorProvider.future,
    );
    return coordinator.recover(email: email, code: code);
  }
}

/// Injectable clock so the resend cooldown is testable.
final recoveryClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// How long a new code can not be requested after one was sent. The server
/// enforces its own limit; this only avoids pointless requests.
const recoveryResendCooldown = Duration(seconds: 60);

sealed class RecoveryState {
  const RecoveryState();
}

/// Step 1: asking for the email address.
final class RecoveryEmailEntry extends RecoveryState {
  const RecoveryEmailEntry({this.email = '', this.failure});

  final String email;
  final EmailAuthFailure? failure;
}

final class RecoveryRequestingCode extends RecoveryState {
  const RecoveryRequestingCode(this.email);

  final String email;
}

/// Step 2: a code was requested (or the user says they have one).
final class RecoveryCodeEntry extends RecoveryState {
  const RecoveryCodeEntry({
    required this.email,
    required this.resendAvailableAt,
    this.failure,
    this.isResending = false,
  });

  final String email;
  final DateTime resendAvailableAt;
  final EmailAuthFailure? failure;
  final bool isResending;
}

final class RecoveryVerifying extends RecoveryState {
  const RecoveryVerifying(this.email);

  final String email;
}

/// The account was restored; the user-scoped root is about to replace the app.
final class RecoverySucceeded extends RecoveryState {
  const RecoverySucceeded(this.identity);

  final AuthIdentity identity;
}

final recoveryFlowProvider =
    NotifierProvider.autoDispose<RecoveryFlowNotifier, RecoveryState>(
      RecoveryFlowNotifier.new,
    );

class RecoveryFlowNotifier extends Notifier<RecoveryState> {
  RecoveryActions get _actions => ref.read(recoveryActionsProvider);
  DateTime get _now => ref.read(recoveryClockProvider)();

  @override
  RecoveryState build() => const RecoveryEmailEntry();

  /// Step 1 -> 2. An unknown address looks the same as a known one here (the
  /// message says "if this address belongs to an account"); the server's
  /// answers still differ, so rate limits there remain essential.
  Future<void> requestCode(String email) async {
    final current = state;
    if (current is! RecoveryEmailEntry) return; // double tap / wrong state
    state = RecoveryRequestingCode(email.trim());
    try {
      await _actions.requestCode(email);
    } catch (e) {
      if (ref.mounted) {
        state = RecoveryEmailEntry(email: email.trim(), failure: _failureOf(e));
      }
      return;
    }
    if (ref.mounted) {
      state = RecoveryCodeEntry(
        email: email.trim(),
        resendAvailableAt: _now.add(recoveryResendCooldown),
      );
    }
  }

  /// For a user who already has a code (for example after the app was closed).
  void haveCode(String email) {
    if (state is! RecoveryEmailEntry) return;
    final trimmed = email.trim();
    if (!_looksLikeEmail(trimmed)) {
      state = RecoveryEmailEntry(
        email: trimmed,
        failure: EmailAuthFailure.invalidEmail,
      );
      return;
    }
    state = RecoveryCodeEntry(email: trimmed, resendAvailableAt: _now);
  }

  void editEmail() {
    final current = state;
    if (current is RecoveryCodeEntry && !current.isResending) {
      state = RecoveryEmailEntry(email: current.email);
    }
  }

  bool canResend(RecoveryCodeEntry s) =>
      !s.isResending && !_now.isBefore(s.resendAvailableAt);

  Future<void> resend() async {
    final current = state;
    if (current is! RecoveryCodeEntry || !canResend(current)) return;
    state = RecoveryCodeEntry(
      email: current.email,
      resendAvailableAt: current.resendAvailableAt,
      isResending: true,
    );
    try {
      await _actions.requestCode(current.email);
    } catch (e) {
      if (ref.mounted) {
        state = RecoveryCodeEntry(
          email: current.email,
          resendAvailableAt: current.resendAvailableAt,
          failure: _failureOf(e),
        );
      }
      return;
    }
    if (ref.mounted) {
      state = RecoveryCodeEntry(
        email: current.email,
        resendAvailableAt: _now.add(recoveryResendCooldown),
      );
    }
  }

  /// Step 2 -> done. The code is only ever a method argument: never stored in
  /// state, preferences or logs.
  Future<void> verify(String code) async {
    final current = state;
    if (current is! RecoveryCodeEntry || current.isResending) return;
    state = RecoveryVerifying(current.email);
    try {
      final identity = await _actions.verify(current.email, code);
      // On success the root scope is replaced and this provider is disposed.
      if (ref.mounted) state = RecoverySucceeded(identity);
    } catch (e) {
      if (!ref.mounted) return;
      state = RecoveryCodeEntry(
        email: current.email,
        resendAvailableAt: current.resendAvailableAt,
        failure: _failureOf(e),
      );
    }
  }

  EmailAuthFailure _failureOf(Object e) {
    return e is EmailAuthException ? e.failure : EmailAuthFailure.serverError;
  }

  bool _looksLikeEmail(String value) {
    final at = value.indexOf('@');
    return at > 0 && at == value.lastIndexOf('@') && at < value.length - 1;
  }
}
