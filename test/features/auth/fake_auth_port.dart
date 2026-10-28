import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Behaves like the local Auth server verified in `test_local_auth/`, with the
/// same error codes, but entirely in memory. It is NOT evidence of how Auth
/// behaves; the real-SDK tests are.
class FakeAuthPort implements AuthPort {
  FakeAuthPort({
    this.userId,
    this.anonymous = true,
    this.email,
    this.accountState = 'active',
  });

  String? userId;
  bool anonymous;
  String? email;
  String? pending;
  String? accountState;

  /// Addresses that already belong to another user.
  final takenEmails = <String>{};

  /// email -> user id of an existing, linked account (recovery targets).
  final accounts = <String, String>{};

  /// States of recoverable accounts, by user id.
  final accountStates = <String, String>{};

  String? linkCode;
  String? signInCode;
  int _counter = 0;

  /// Everything the repository asked of the server, in order.
  final calls = <String>[];

  Object? identityError;
  Object? stateError;
  Object? requestError;
  Object? verifyError;

  @override
  String? get currentUserId => userId;

  @override
  bool get cachedUserIsLinked => userId != null && !anonymous && email != null;

  AuthIdentity _identity() => AuthIdentity(
    userId: userId!,
    isAnonymous: anonymous,
    email: email,
    pendingEmail: pending,
    isEmailConfirmed: !anonymous && email != null,
  );

  AuthApiException _api(String status, String code) =>
      AuthApiException('server message', statusCode: status, code: code);

  @override
  Future<AuthIdentity> fetchIdentity() async {
    calls.add('fetchIdentity');
    if (identityError != null) throw identityError!;
    if (userId == null) throw AuthSessionMissingException();
    return _identity();
  }

  @override
  Future<AuthIdentity> requestEmailChange(String address) async {
    calls.add('requestEmailChange:$address');
    if (requestError != null) throw requestError!;
    if (takenEmails.contains(address)) throw _api('422', 'email_exists');
    pending = address;
    linkCode = (++_counter).toString().padLeft(6, '1');
    return _identity();
  }

  @override
  Future<AuthIdentity> verifyEmailChange(String address, String code) async {
    calls.add('verifyEmailChange');
    if (verifyError != null) throw verifyError!;
    if (code != linkCode || pending != address) {
      throw _api('403', 'otp_expired');
    }
    linkCode = null;
    email = address;
    pending = null;
    anonymous = false;
    return _identity();
  }

  @override
  Future<void> requestSignInCode(String address) async {
    calls.add('requestSignInCode:$address');
    if (requestError != null) throw requestError!;
    // shouldCreateUser: false -> an unknown address is refused, not created.
    if (!accounts.containsKey(address)) throw _api('422', 'otp_disabled');
    signInCode = '222222';
  }

  @override
  Future<AuthIdentity> verifySignInCode(String address, String code) async {
    calls.add('verifySignInCode');
    if (verifyError != null) throw verifyError!;
    if (code != signInCode || !accounts.containsKey(address)) {
      throw _api('403', 'otp_expired');
    }
    signInCode = null;
    userId = accounts[address];
    anonymous = false;
    email = address;
    pending = null;
    accountState = accountStates[userId] ?? 'active';
    return _identity();
  }

  @override
  Future<String?> readAccountState() async {
    calls.add('readAccountState');
    if (stateError != null) throw stateError!;
    return accountState;
  }

  @override
  Future<void> signOutLocal() async {
    calls.add('signOutLocal');
    userId = null;
    anonymous = true;
    email = null;
    pending = null;
  }
}
