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

  /// Asks the trusted backend to delete the caller's own account. The target
  /// is never sent: the function derives it from the verified session.
  Future<void> deleteAccount() async {
    try {
      await _client.functions.invoke(
        'delete-account',
        body: {'confirmation': 'DELETE'},
      );
    } on FunctionException catch (e) {
      if (e.status == 409) {
        throw const AccountDeletionException(
          AccountDeletionFailure.ownsHouseholds,
        );
      }
      throw const AccountDeletionException(AccountDeletionFailure.retryable);
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
