import 'package:flutter/foundation.dart';

@immutable
class ShoppingItem {
  const ShoppingItem({
    required this.id,
    required this.householdId,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.quantity,
    this.completedAt,
    this.completedBy,
  });

  final String id;
  final String householdId;
  final String name;
  final String? quantity;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? completedBy;

  bool get isCompleted => completedAt != null;

  factory ShoppingItem.fromMap(Map<String, dynamic> map) {
    return ShoppingItem(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      name: map['name'] as String,
      quantity: map['quantity'] as String?,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      completedAt: map['completed_at'] == null
          ? null
          : DateTime.parse(map['completed_at'] as String),
      completedBy: map['completed_by'] as String?,
    );
  }
}
