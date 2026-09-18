import 'package:flutter/foundation.dart';

@immutable
class Household {
  const Household({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;

  static String? validateName(String name) {
    if (name.trim().isEmpty) return 'Household name cannot be blank';
    return null;
  }

  factory Household.fromMap(Map<String, dynamic> map) {
    return Household(
      id: map['id'] as String,
      name: map['name'] as String,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
