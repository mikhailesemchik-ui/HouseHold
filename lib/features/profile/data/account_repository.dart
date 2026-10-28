import 'package:household_os/features/auth/data/auth_port.dart';
import 'package:household_os/features/auth/data/email_account_repository.dart';
import 'package:household_os/features/auth/domain/email_auth_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A household the user still owns, which blocks account deletion.
class OwnedHousehold {
  const OwnedHousehold({required this.name, required this.activeMemberCount});

  final String name;
  final int activeMemberCount;
}

/// Why the server refused or could not finish deleting the account.
enum AccountDeletionFailure {
  /// The user still owns households (HTTP 409).
  ownsHouseholds,

  /// Cleanup is only partly done; the same request can simply be repeated.
  retryable,

  /// An email-linked account must send a fresh emailed code (HTTP 403).
  verificationRequired,

  /// The emailed code was wrong, expired or already used. Nothing was started.
  codeRejected,

  /// Too many verification attempts; wait and try again. Nothing was started.
  rateLimited,

  /// The code could not be checked right now. Nothing was started.
  verificationUnavailable,

  /// The signed-in user is not the one who opened the flow.
  sessionChanged,
}

/// True when the server refused the request before changing anything, so the
/// local "deletion attempted" marker can be dropped.
extension AccountDeletionFailureX on AccountDeletionFailure {
  bool get leavesAccountUntouched => this != AccountDeletionFailure.retryable;
}

/// Maps the Edge Function's answer to a failure. Only the machine-readable
/// error key is read; nothing the server wrote is shown or stored.
AccountDeletionFailure accountDeletionFailureFor(int status, Object? details) {
  final key = details is Map ? details['error'] : null;
  if (status == 409) return AccountDeletionFailure.ownsHouseholds;
  if (status == 429) return AccountDeletionFailure.rateLimited;
  if (status == 403) {
    return switch (key) {
      'reverification_required' => AccountDeletionFailure.verificationRequired,
      'verification_failed' => AccountDeletionFailure.codeRejected,
      _ => AccountDeletionFailure.verificationUnavailable,
    };
  }
  if (status == 502 && key == 'verification_unavailable') {
    return AccountDeletionFailure.verificationUnavailable;
  }
  return AccountDeletionFailure.retryable;
}

class AccountDeletionException implements Exception {
  const AccountDeletionException(this.failure);

  final AccountDeletionFailure failure;

  @override
  String toString() => 'AccountDeletionException($failure)';
}

class AccountRepository {
  const AccountRepository(this._client);

  final SupabaseClient _client;

  /// Households the caller owns; they must be transferred or deleted first.
  Future<List<OwnedHousehold>> fetchBlockers() async {
    final rows = await _client.rpc('account_deletion_blockers');
    return (rows as List)
        .map(
          (row) => OwnedHousehold(
            name: row['name'] as String,
            activeMemberCount: (row['active_member_count'] as num).toInt(),
          ),
        )
        .toList();
  }

  /// The signed-in user, to detect an account change during the flow.
  String? get currentUserId => _client.auth.currentUser?.id;

  /// Emails a fresh code to the signed-in account's confirmed email (never an
  /// address the caller supplies). The code is verified by the backend, not
  /// here, and this does not change the session. Throws [EmailAuthException].
  Future<void> sendDeletionCode() async {
    final emails = EmailAccountRepository(SupabaseAuthPort(_client));
    final identity = await emails.currentIdentity();
    final email = identity.email;
    if (!identity.isLinked || email == null) {
      throw const EmailAuthException(EmailAuthFailure.notSignedIn);
    }
    await emails.sendRecoveryCode(email);
  }

  /// Asks the trusted backend to delete the caller's own account. The target
  /// is never sent: the function derives it from the verified session. An
  /// email-linked account must also pass [code], the emailed code, which is
  /// checked only by the backend.
  Future<void> deleteAccount({String? code}) async {
    try {
      await _client.functions.invoke(
        'delete-account',
        body: {'confirmation': 'DELETE', 'code': ?code},
      );
    } on FunctionException catch (e) {
      throw AccountDeletionException(
        accountDeletionFailureFor(e.status, e.details),
      );
    }
  }

  /// Whether the account is certainly gone (true), certainly not (false) or
  /// cannot be told right now (null). A rejected or missing session counts
  /// as gone: the Auth user cannot be signed in to any more.
  Future<bool?> isAccountGone(String userId) async {
    if (_client.auth.currentSession == null) return true;
    try {
      final rows = await _client
          .from('profiles')
          .select('account_state')
          .eq('user_id', userId)
          .limit(1);
      if (rows.isEmpty) return true;
      return rows.first['account_state'] == 'deleted';
    } on AuthException {
      return true;
    } on PostgrestException catch (e) {
      return (e.code ?? '').startsWith('PGRST30') ? true : null;
    } catch (_) {
      return null;
    }
  }

  /// Ends the local session only. The server user is already gone, so a
  /// global sign-out request would just fail.
  Future<void> endLocalSession() {
    return _client.auth.signOut(scope: SignOutScope.local);
  }
}
