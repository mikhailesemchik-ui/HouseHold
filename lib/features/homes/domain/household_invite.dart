import 'package:flutter/foundation.dart';

@immutable
class HouseholdInvite {
  const HouseholdInvite({
    required this.id,
    required this.householdId,
    required this.code,
    required this.createdBy,
    required this.createdAt,
    this.expiresAt,
    this.revokedAt,
  });

  final String id;
  final String householdId;
  final String code;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  bool get isActive {
    if (revokedAt != null) return false;
    final expires = expiresAt;
    return expires == null || expires.isAfter(DateTime.now());
  }

  factory HouseholdInvite.fromMap(Map<String, dynamic> map) {
    return HouseholdInvite(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      code: map['code'] as String,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      expiresAt: map['expires_at'] != null
          ? DateTime.parse(map['expires_at'] as String)
          : null,
      revokedAt: map['revoked_at'] != null
          ? DateTime.parse(map['revoked_at'] as String)
          : null,
    );
  }
}
