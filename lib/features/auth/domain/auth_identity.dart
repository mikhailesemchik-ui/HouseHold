import 'package:flutter/foundation.dart';

/// What the Auth server says about a user. Built from a server response, never
/// from locally cached metadata, wherever it is used as proof of linking.
@immutable
class AuthIdentity {
  const AuthIdentity({
    required this.userId,
    required this.isAnonymous,
    this.email,
    this.pendingEmail,
    this.isEmailConfirmed = false,
  });

  final String userId;
  final bool isAnonymous;
  final String? email;

  /// An address that was requested but not yet confirmed with a code. It lives
  /// on the server, so it survives an app restart mid-verification.
  final String? pendingEmail;
  final bool isEmailConfirmed;

  /// A permanent user with a confirmed email: recoverable on another device.
  bool get isLinked =>
      !isAnonymous && isEmailConfirmed && (email?.isNotEmpty ?? false);
}
