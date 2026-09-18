import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_invite.dart';
import 'package:household_os/features/homes/domain/membership_period.dart';

class HouseholdRepository {
  const HouseholdRepository(this._client);

  final SupabaseClient _client;

  Future<List<Household>> fetchActiveHouseholds() async {
    final rows = await _client.from('households').select().order('created_at');
    return rows.map(Household.fromMap).toList();
  }

  Future<Household?> fetchHousehold(String id) async {
    final rows = await _client
        .from('households')
        .select()
        .eq('id', id)
        .limit(1);
    if (rows.isEmpty) return null;
    return Household.fromMap(rows.first);
  }

  Future<Household> createHousehold(String name) async {
    final data = await _client.rpc(
      'create_household',
      params: {'p_name': name},
    );
    return _householdFromRpc(data);
  }

  Future<Household> joinHousehold(String inviteCode) async {
    final data = await _client.rpc(
      'join_household_by_invite',
      params: {'p_code': normalizeInviteCode(inviteCode)},
    );
    return _householdFromRpc(data);
  }

  Future<void> leaveHousehold(String householdId) async {
    await _client.rpc(
      'leave_household',
      params: {'p_household_id': householdId},
    );
  }

  Future<void> removeMember({
    required String householdId,
    required String userId,
  }) async {
    await _client.rpc(
      'remove_household_member',
      params: {'p_household_id': householdId, 'p_user_id': userId},
    );
  }

  Future<void> transferOwnership({
    required String householdId,
    required String newOwnerId,
  }) async {
    await _client.rpc(
      'transfer_household_ownership',
      params: {'p_household_id': householdId, 'p_new_owner_id': newOwnerId},
    );
  }

  Future<HouseholdInvite> createInvite(String householdId) async {
    final data = await _client.rpc(
      'create_household_invite',
      params: {'p_household_id': householdId},
    );
    return _inviteFromRpc(data);
  }

  Future<List<HouseholdInvite>> fetchActiveInvites(String householdId) async {
    final rows = await _client
        .from('household_invites')
        .select()
        .eq('household_id', householdId)
        .order('created_at');
    return rows.map(HouseholdInvite.fromMap).where((i) => i.isActive).toList();
  }

  Future<void> revokeInvite(String inviteId) async {
    await _client.rpc(
      'revoke_household_invite',
      params: {'p_invite_id': inviteId},
    );
  }

  Future<List<MembershipPeriod>> fetchMembershipPeriods(
    String householdId,
  ) async {
    final rows = await _client
        .from('household_membership_periods')
        .select()
        .eq('household_id', householdId)
        .order('joined_at');
    return rows.map(MembershipPeriod.fromMap).toList();
  }

  // Normalizes user-supplied invite codes to the canonical XXXX-XXXX format.
  // Strips whitespace and non-alphanumeric characters, uppercases, inserts dash.
  static String normalizeInviteCode(String code) {
    final stripped = code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (stripped.length == 8) {
      return '${stripped.substring(0, 4)}-${stripped.substring(4)}';
    }
    return stripped;
  }

  static String? validateInviteCode(String code) {
    final normalized = normalizeInviteCode(code);
    if (!RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(normalized)) {
      return 'Enter a valid invite code (e.g. ABCD-EFGH)';
    }
    return null;
  }

  static Household _householdFromRpc(dynamic data) {
    if (data is Map<String, dynamic>) return Household.fromMap(data);
    if (data is List && data.isNotEmpty) {
      return Household.fromMap(data.first as Map<String, dynamic>);
    }
    throw StateError('Unexpected response format from household RPC');
  }

  static HouseholdInvite _inviteFromRpc(dynamic data) {
    if (data is Map<String, dynamic>) return HouseholdInvite.fromMap(data);
    if (data is List && data.isNotEmpty) {
      return HouseholdInvite.fromMap(data.first as Map<String, dynamic>);
    }
    throw StateError('Unexpected response format from invite RPC');
  }
}
