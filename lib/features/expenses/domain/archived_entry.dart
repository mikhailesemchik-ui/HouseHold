import 'package:flutter/foundation.dart';

/// A cancelled expense or payment, as preserved by `financial_archive`.
///
/// Read-only: archived entries cannot be edited or restored.
@immutable
class ArchivedEntry {
  const ArchivedEntry({
    required this.id,
    required this.isExpense,
    required this.title,
    required this.amountCents,
    required this.currency,
    required this.canceledByName,
    required this.canceledAt,
    this.reason,
  });

  final String id;
  final bool isExpense;
  final String title;
  final int amountCents;
  final String currency;
  final String canceledByName;
  final DateTime canceledAt;
  final String? reason;

  factory ArchivedEntry.fromMap(Map<String, dynamic> map) {
    final snapshot = Map<String, dynamic>.from(map['snapshot'] as Map);
    final isExpense = map['kind'] == 'expense';
    final title = isExpense
        ? (snapshot['title'] as String? ?? 'Expense')
        : '${snapshot['from_name'] ?? 'Someone'} paid '
              '${snapshot['to_name'] ?? 'someone'}';
    return ArchivedEntry(
      id: map['id'] as String,
      isExpense: isExpense,
      title: title,
      amountCents: (snapshot['amount_cents'] as num).toInt(),
      currency: snapshot['currency'] as String? ?? 'EUR',
      canceledByName: map['canceled_by_name'] as String? ?? 'Someone',
      canceledAt: DateTime.parse(map['canceled_at'] as String),
      reason: map['reason'] as String?,
    );
  }
}
