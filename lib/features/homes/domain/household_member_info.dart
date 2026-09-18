import 'package:flutter/foundation.dart';

@immutable
class HouseholdMemberInfo {
  const HouseholdMemberInfo({
    required this.userId,
    required this.displayName,
    required this.publicId,
    required this.role,
    required this.joinedAt,
  });

  final String userId;
  final String displayName;
  final String publicId;

  /// 'owner' or 'member'
  final String role;
  final DateTime joinedAt;

  bool get isOwner => role == 'owner';

  factory HouseholdMemberInfo.fromMap(Map<String, dynamic> map) {
    final profile = map['profiles'] as Map<String, dynamic>?;
    return HouseholdMemberInfo(
      userId: map['user_id'] as String,
      displayName: profile?['display_name'] as String? ?? 'Unknown',
      publicId: profile?['public_id'] as String? ?? '',
      role: map['role'] as String,
      joinedAt: DateTime.parse(map['joined_at'] as String),
    );
  }
}
