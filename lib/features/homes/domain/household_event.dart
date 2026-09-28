import 'package:flutter/foundation.dart';

@immutable
class HouseholdEvent {
  const HouseholdEvent({
    required this.id,
    required this.householdId,
    required this.actorDisplayName,
    required this.eventType,
    required this.entityType,
    required this.occurredAt,
    this.actorUserId,
    this.entityId,
    this.titleSnapshot,
    this.amountCents,
    this.currency,
  });

  final String id;
  final String householdId;
  final String? actorUserId;
  final String actorDisplayName;
  final String eventType;
  final String entityType;
  final String? entityId;
  final String? titleSnapshot;
  final int? amountCents;
  final String? currency;
  final DateTime occurredAt;

  /// Human-readable description for the activity feed.
  String get displayText {
    final actor = actorDisplayName;
    final title = titleSnapshot ?? '(unknown)';
    return switch (eventType) {
      'task_created' => '$actor created "$title"',
      'task_completed' => '$actor completed "$title"',
      'task_reopened' => '$actor reopened "$title"',
      'task_deleted' => '$actor deleted "$title"',
      'shopping_item_added' => '$actor added "$title"',
      'shopping_item_completed' => '$actor completed "$title"',
      'shopping_item_reopened' => '$actor reopened "$title"',
      'expense_created' =>
        amountCents != null
            ? '$actor added expense "$title" - ${_formatAmount()}'
            : '$actor added expense "$title"',
      'expense_deleted' => '$actor deleted expense "$title"',
      'member_joined' => '$actor joined',
      'member_left' => '$actor left',
      'member_removed' => '$actor removed $title',
      'ownership_transferred' => '$actor transferred ownership to $title',
      _ => '$actor performed an action',
    };
  }

  String _formatAmount() {
    final cents = amountCents!;
    final cur = currency ?? 'EUR';
    const symbols = {'EUR': '€', 'USD': '\$', 'GBP': '£'};
    final symbol = symbols[cur] ?? cur;
    final whole = cents ~/ 100;
    final fraction = (cents % 100).toString().padLeft(2, '0');
    return '$symbol$whole.$fraction';
  }

  factory HouseholdEvent.fromMap(Map<String, dynamic> map) {
    return HouseholdEvent(
      id: map['id'] as String,
      householdId: map['household_id'] as String,
      actorUserId: map['actor_user_id'] as String?,
      actorDisplayName:
          map['actor_display_name'] as String? ?? 'Deleted member',
      eventType: map['event_type'] as String,
      entityType: map['entity_type'] as String,
      entityId: map['entity_id'] as String?,
      titleSnapshot: map['title_snapshot'] as String?,
      amountCents: (map['amount_cents'] as num?)?.toInt(),
      currency: map['currency'] as String?,
      occurredAt: DateTime.parse(map['occurred_at'] as String),
    );
  }
}
