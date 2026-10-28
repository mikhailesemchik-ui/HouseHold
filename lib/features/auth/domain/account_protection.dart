import 'package:household_os/features/auth/domain/auth_identity.dart';

/// How well an account can be recovered, from what the Auth SERVER says.
///
/// A submitted email address is not protection: only a confirmed email on a
/// permanent user is. A pending address is kept apart for that reason.
sealed class AccountProtection {
  const AccountProtection(this.userId);

  final String userId;
}

/// Anonymous, nothing requested: the only way back in is this device's session.
final class AccountUnprotected extends AccountProtection {
  const AccountUnprotected(super.userId);
}

/// Anonymous, with an email waiting for its code. Still unprotected.
final class AccountVerificationPending extends AccountProtection {
  const AccountVerificationPending(super.userId, this.email);

  final String email;
}

/// A confirmed email on a permanent user: recoverable on another device.
final class AccountProtected extends AccountProtection {
  const AccountProtected(super.userId, this.email);

  final String email;
}

/// Null for an identity that fits none of the three (nothing is offered).
AccountProtection? protectionOf(AuthIdentity identity) {
  if (identity.isLinked) {
    return AccountProtected(identity.userId, identity.email!);
  }
  if (!identity.isAnonymous) return null;
  final pending = identity.pendingEmail;
  if (pending != null && pending.isNotEmpty) {
    return AccountVerificationPending(identity.userId, pending);
  }
  return AccountUnprotected(identity.userId);
}
