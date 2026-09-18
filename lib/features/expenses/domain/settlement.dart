import 'package:flutter/foundation.dart';

@immutable
class Settlement {
  const Settlement({
    required this.id,
    required this.householdId,
    required this.fromUserId,
    required this.fromName,
    required this.toUserId,
    required this.toName,
    required this.amountCents,
    required this.currency,
    required this.createdBy,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String householdId;
  final String fromUserId;
  final String fromName;
  final String toUserId;
  final String toName;
  final int amountCents;
  final String currency;
  final String? note;
  final String createdBy;
  final DateTime createdAt;

  factory Settlement.fromMap(Map<String, dynamic> map) {
    return Settlement(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      fromUserId: map['from_user_id'] as String,
      fromName: map['from_name'] as String? ?? 'Deleted member',
      toUserId: map['to_user_id'] as String,
      toName: map['to_name'] as String? ?? 'Deleted member',
      amountCents: (map['amount_cents'] as num).toInt(),
      currency: map['currency'] as String,
      note: map['note'] as String?,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
