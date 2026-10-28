import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/domain/account_protection.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:household_os/features/auth/presentation/auth_providers.dart';
import 'package:household_os/features/auth/presentation/recovery_flow.dart';

/// What linking needs: ask for a code for the CURRENT anonymous user and check
/// one. The real implementation is the F1 repository (`updateUser(email)` then
/// `verifyOTP(emailChange)`); neither step can sign in as anyone else or create
/// a second account.
abstract interface class LinkEmailActions {
  String? get currentUserId;

  Future<AuthIdentity> sendCode(String email);

  /// Completes the link for [expectedUserId] and returns the identity that the
  /// Auth server reports afterwards.
  Future<AuthIdentity> verify({
    required String expectedUserId,
    required String email,
    required String code,
  });
}

final linkEmailActionsProvider = Provider<LinkEmailActions>((ref) {
  return _RepositoryLinkActions(ref.watch(emailAccountRepositoryProvider));
});

class _RepositoryLinkActions implements LinkEmailActions {
  _RepositoryLinkActions(this._repository);

  final EmailAccountRepository _repository;

  @override
  String? get currentUserId => _repository.currentUserId;

  @override
  Future<AuthIdentity> sendCode(String email) =>
      _repository.sendLinkCode(email);

  // The repository only returns after the server identity is the same user,
  // permanent and confirmed for this email.
  @override
  Future<AuthIdentity> verify({
    required String expectedUserId,
    required String email,
    required String code,
  }) {
    return _repository.verifyLinkCode(
      expectedUserId: expectedUserId,
      email: email,
      code: code,
    );
  }
}

sealed class LinkEmailState {
  const LinkEmailState();
}

/// Step 1.
final class LinkEmailEntry extends LinkEmailState {
  const LinkEmailEntry({this.email = '', this.failure});

  final String email;
  final EmailAuthFailure? failure;
}

final class LinkEmailRequesting extends LinkEmailState {
  const LinkEmailRequesting(this.email);

  final String email;
}

/// Step 2. [userId] is the identity the code was requested for.
final class LinkEmailCodeEntry extends LinkEmailState {
  const LinkEmailCodeEntry({
    required this.email,
    required this.userId,
    required this.resendAvailableAt,
    this.failure,
    this.isResending = false,
  });

  final String email;
  final String userId;
  final DateTime resendAvailableAt;
  final EmailAuthFailure? failure;
  final bool isResending;
}

final class LinkEmailVerifying extends LinkEmailState {
  const LinkEmailVerifying(this.email);

  final String email;
}

/// The server confirmed the email on the same user.
final class LinkEmailDone extends LinkEmailState {
  const LinkEmailDone(this.identity);

  final AuthIdentity identity;
}

final linkEmailFlowProvider =
    NotifierProvider.autoDispose<LinkEmailFlowNotifier, LinkEmailState>(
      LinkEmailFlowNotifier.new,
    );

class LinkEmailFlowNotifier extends Notifier<LinkEmailState> {
  LinkEmailActions get _actions => ref.read(linkEmailActionsProvider);
  DateTime get _now => ref.read(recoveryClockProvider)();

  @override
  LinkEmailState build() => const LinkEmailEntry();

  /// Step 1 -> 2. Binds the flow to the user who is signed in right now.
  Future<void> requestCode(String email) async {
    if (state is! LinkEmailEntry) return; // double tap / wrong state
    final userId = _actions.currentUserId;
    final typed = email.trim();
    if (userId == null) {
      state = LinkEmailEntry(
        email: typed,
        failure: EmailAuthFailure.notSignedIn,
      );
      return;
    }
    state = LinkEmailRequesting(typed);
    try {
      final identity = await _actions.sendCode(email);
      if (!ref.mounted) return;
      state = LinkEmailCodeEntry(
        email: identity.pendingEmail ?? typed.toLowerCase(),
        userId: userId,
        resendAvailableAt: _now.add(recoveryResendCooldown),
      );
    } catch (e) {
      if (ref.mounted) {
        state = LinkEmailEntry(email: typed, failure: _failureOf(e));
      }
    }
  }

  /// Resumes a verification that is already pending on the server (for example
  /// after the app was closed): no new code is requested.
  void resumePending(AccountVerificationPending pending) {
    if (state is! LinkEmailEntry) return;
    state = LinkEmailCodeEntry(
      email: pending.email,
      userId: pending.userId,
      resendAvailableAt: _now,
    );
  }

  void editEmail() {
    final current = state;
    if (current is LinkEmailCodeEntry && !current.isResending) {
      state = LinkEmailEntry(email: current.email);
    }
  }

  bool canResend(LinkEmailCodeEntry s) =>
      !s.isResending && !_now.isBefore(s.resendAvailableAt);

  /// A new code is another `updateUser(email)` for the same user; the
  /// unauthenticated `resend(emailChange)` sends nothing usable here.
  Future<void> resend() async {
    final current = state;
    if (current is! LinkEmailCodeEntry || !canResend(current)) return;
    if (_actions.currentUserId != current.userId) {
      state = _again(current, EmailAuthFailure.sessionChanged);
      return;
    }
    state = LinkEmailCodeEntry(
      email: current.email,
      userId: current.userId,
      resendAvailableAt: current.resendAvailableAt,
      isResending: true,
    );
    try {
      await _actions.sendCode(current.email);
      if (!ref.mounted) return;
      state = LinkEmailCodeEntry(
        email: current.email,
        userId: current.userId,
        resendAvailableAt: _now.add(recoveryResendCooldown),
      );
    } catch (e) {
      if (ref.mounted) state = _again(current, _failureOf(e));
    }
  }

  /// Step 2 -> done. The code is only ever a method argument.
  Future<void> verify(String code) async {
    final current = state;
    if (current is! LinkEmailCodeEntry || current.isResending) return;
    state = LinkEmailVerifying(current.email);
    try {
      final identity = await _actions.verify(
        expectedUserId: current.userId,
        email: current.email,
        code: code,
      );
      if (ref.mounted) state = LinkEmailDone(identity);
    } catch (e) {
      if (ref.mounted) state = _again(current, _failureOf(e));
    }
  }

  LinkEmailCodeEntry _again(LinkEmailCodeEntry from, EmailAuthFailure failure) {
    return LinkEmailCodeEntry(
      email: from.email,
      userId: from.userId,
      resendAvailableAt: from.resendAvailableAt,
      failure: failure,
    );
  }

  EmailAuthFailure _failureOf(Object e) {
    return e is EmailAuthException ? e.failure : EmailAuthFailure.serverError;
  }
}
