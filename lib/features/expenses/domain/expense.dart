import 'package:flutter/foundation.dart';

@immutable
class ExpenseParticipant {
  const ExpenseParticipant({
    required this.expenseId,
    required this.userId,
    required this.displayName,
    required this.shareCents,
  });

  final String expenseId;
  final String userId;
  final String displayName;
  final int shareCents;

  factory ExpenseParticipant.fromMap(Map<String, dynamic> map) {
    return ExpenseParticipant(
      expenseId: map['expense_id'] as String,
      userId: map['user_id'] as String,
      displayName: map['display_name'] as String? ?? 'Deleted member',
      shareCents: (map['share_cents'] as num).toInt(),
    );
  }
}

@immutable
class Expense {
  const Expense({
    required this.id,
    required this.householdId,
    required this.title,
    required this.amountCents,
    required this.currency,
    required this.paidBy,
    required this.paidByDisplayName,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.participants,
  });

  final String id;
  final String householdId;
  final String title;
  final int amountCents;
  final String currency;
  final String paidBy;
  final String paidByDisplayName;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ExpenseParticipant> participants;

  factory Expense.fromMap(
    Map<String, dynamic> map,
    List<ExpenseParticipant> participants,
  ) {
    return Expense(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      title: map['title'] as String,
      amountCents: (map['amount_cents'] as num).toInt(),
      currency: map['currency'] as String,
      paidBy: map['paid_by'] as String,
      paidByDisplayName:
          map['paid_by_display_name'] as String? ?? 'Deleted member',
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      participants: participants,
    );
  }
}

@immutable
class ExpenseMember {
  const ExpenseMember({required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  factory ExpenseMember.fromMap(Map<String, dynamic> map) {
    final profile = map['profiles'] as Map<String, dynamic>?;
    return ExpenseMember(
      userId: map['user_id'] as String,
      displayName: profile?['display_name'] as String? ?? 'Unknown',
    );
  }
}
