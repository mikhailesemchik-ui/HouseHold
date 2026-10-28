/// Display labels for people in historical household data.
///
/// Two separate facts decide a label: whether the ACCOUNT was deleted (trusted
/// `profiles.account_state`) and whether the person is currently an active
/// MEMBER of the household. A missing profile or missing membership is never
/// taken as proof of deletion.
library;

const deletedMemberLabel = 'Deleted member';
const formerMemberLabel = 'Former member';
const unknownMemberLabel = 'Someone';

enum MemberIdentityState {
  /// A known name; the person is a current member, or membership is not known.
  active,

  /// A known name and the household's member list says they are not active.
  former,

  /// The trusted account state says the account was deleted.
  deleted,

  /// No usable name and no deletion evidence (e.g. an inaccessible profile).
  unknown,
}

/// Deletion wins over membership; a blank name without deletion evidence is
/// unknown. [isActiveMember] is null when membership data is unavailable, which
/// never makes someone "former".
MemberIdentityState resolveMemberIdentityState({
  String? accountState,
  bool? isActiveMember,
  String? displayName,
}) {
  if (accountState == 'deleted') return MemberIdentityState.deleted;
  if (displayName == null || displayName.trim().isEmpty) {
    return MemberIdentityState.unknown;
  }
  if (isActiveMember == false) return MemberIdentityState.former;
  return MemberIdentityState.active;
}

/// Label where the member list is the source of truth (statistics, rotation).
/// A former member's real name is deliberately not shown there.
String memberStatsLabel({
  String? accountState,
  bool? isActiveMember,
  String? displayName,
}) {
  return switch (resolveMemberIdentityState(
    accountState: accountState,
    isActiveMember: isActiveMember,
    displayName: displayName,
  )) {
    MemberIdentityState.deleted => deletedMemberLabel,
    MemberIdentityState.unknown => unknownMemberLabel,
    MemberIdentityState.former => formerMemberLabel,
    MemberIdentityState.active => displayName!.trim(),
  };
}

/// Label where only the profile is known (activity feeds): the stored name, or
/// a neutral fallback. Membership is not looked up, so no "(former)" suffix.
String memberNameLabel({String? accountState, String? displayName}) =>
    memberStatsLabel(accountState: accountState, displayName: displayName);
