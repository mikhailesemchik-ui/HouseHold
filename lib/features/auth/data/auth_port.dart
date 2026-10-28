import 'package:household_os/features/auth/domain/auth_identity.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The few Supabase Auth calls F1 needs, so the flow logic can be tested
/// without a server. [SupabaseAuthPort] is the only real implementation and is
/// exercised against local Auth by `test_local_auth/`.
abstract interface class AuthPort {
  String? get currentUserId;

  /// Cached on this device: a safety hint only, never proof of linking.
  bool get cachedUserIsLinked;

  /// The server's view of the signed-in user.
  Future<AuthIdentity> fetchIdentity();

  /// Asks the server to attach [email] to the signed-in anonymous user.
  Future<AuthIdentity> requestEmailChange(String email);

  Future<AuthIdentity> verifyEmailChange(String email, String code);

  /// Sends a sign-in code to an existing user. Never registers a new one.
  Future<void> requestSignInCode(String email);

  Future<AuthIdentity> verifySignInCode(String email, String code);

  /// `profiles.account_state` of the signed-in user, or null without a row.
  Future<String?> readAccountState();

  /// Ends only this device's session; other devices stay signed in.
  Future<void> signOutLocal();
}

class SupabaseAuthPort implements AuthPort {
  const SupabaseAuthPort(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  String? get currentUserId => _auth.currentUser?.id;

  @override
  bool get cachedUserIsLinked {
    final user = _auth.currentUser;
    return user != null && !user.isAnonymous && user.email != null;
  }

  @override
  Future<AuthIdentity> fetchIdentity() async {
    final response = await _auth.getUser();
    return _identity(response.user);
  }

  @override
  Future<AuthIdentity> requestEmailChange(String email) async {
    final response = await _auth.updateUser(UserAttributes(email: email));
    return _identity(response.user);
  }

  @override
  Future<AuthIdentity> verifyEmailChange(String email, String code) async {
    final response = await _auth.verifyOTP(
      email: email,
      token: code,
      type: OtpType.emailChange,
    );
    return _identity(_requireSession(response).user);
  }

  @override
  Future<void> requestSignInCode(String email) {
    return _auth.signInWithOtp(email: email, shouldCreateUser: false);
  }

  @override
  Future<AuthIdentity> verifySignInCode(String email, String code) async {
    final response = await _auth.verifyOTP(
      email: email,
      token: code,
      type: OtpType.email,
    );
    return _identity(_requireSession(response).user);
  }

  @override
  Future<String?> readAccountState() async {
    final userId = currentUserId;
    if (userId == null) return null;
    final rows = await _client
        .from('profiles')
        .select('account_state')
        .eq('user_id', userId)
        .limit(1);
    return rows.isEmpty ? null : rows.first['account_state'] as String?;
  }

  @override
  Future<void> signOutLocal() => _auth.signOut(scope: SignOutScope.local);

  AuthResponse _requireSession(AuthResponse response) {
    // A change that needs a second confirmation returns no session yet.
    if (response.session == null || response.user == null) {
      throw const AuthException('Verification is not complete');
    }
    return response;
  }

  AuthIdentity _identity(User? user) {
    if (user == null) throw const AuthException('No user in response');
    return AuthIdentity(
      userId: user.id,
      isAnonymous: user.isAnonymous,
      email: user.email,
      pendingEmail: user.newEmail,
      isEmailConfirmed: user.emailConfirmedAt != null,
    );
  }
}
