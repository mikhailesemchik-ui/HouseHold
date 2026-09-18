import 'package:flutter/foundation.dart';

@immutable
class MembershipPeriod {
  const MembershipPeriod({
    required this.id,
    required this.householdId,
    required this.userId,
    required this.joinedAt,
    this.leftAt,
  });

  final String id;
  final String householdId;
  final String userId;
  final DateTime joinedAt;
  final DateTime? leftAt;

  bool get isCurrent => leftAt == null;

  factory MembershipPeriod.fromMap(Map<String, dynamic> map) =>
      MembershipPeriod(
        id: map['id'] as String,
        householdId: map['household_id'] as String,
        userId: map['user_id'] as String,
        joinedAt: DateTime.parse(map['joined_at'] as String),
        leftAt: map['left_at'] == null
            ? null
            : DateTime.parse(map['left_at'] as String),
      );
}
