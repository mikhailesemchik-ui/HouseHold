import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/shopping/domain/shopping_item.dart';

class ShoppingRepository {
  const ShoppingRepository(this._client);

  final SupabaseClient _client;

  /// Streams all items for [householdId] via Supabase Realtime.
  /// Incomplete items appear first (newest created first), then completed
  /// (oldest completed first so they accumulate below).
  Stream<List<ShoppingItem>> watchItems(String householdId) {
    return _client
        .from('shopping_items')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('created_at', ascending: false)
        .map((rows) {
          final items = rows.map(ShoppingItem.fromMap).toList();
          items.sort((a, b) {
            if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
            if (!a.isCompleted) {
              return b.createdAt.compareTo(a.createdAt);
            }
            return a.completedAt!.compareTo(b.completedAt!);
          });
          return items;
        });
  }

  Future<void> addItem({
    required String householdId,
    required String name,
    String? quantity,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');
    await _client.from('shopping_items').insert({
      'household_id': householdId,
      'name': name.trim(),
      'quantity': quantity != null && quantity.trim().isNotEmpty
          ? quantity.trim()
          : null,
      'created_by': userId,
    });
  }

  Future<void> updateItem({
    required String itemId,
    required String name,
    String? quantity,
  }) async {
    await _client
        .from('shopping_items')
        .update({
          'name': name.trim(),
          'quantity': quantity != null && quantity.trim().isNotEmpty
              ? quantity.trim()
              : null,
        })
        .eq('id', itemId);
  }

  Future<void> completeItem(String itemId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not authenticated');
    await _client
        .from('shopping_items')
        .update({
          'completed_at': DateTime.now().toUtc().toIso8601String(),
          'completed_by': userId,
        })
        .eq('id', itemId);
  }

  Future<void> reopenItem(String itemId) async {
    await _client
        .from('shopping_items')
        .update({'completed_at': null, 'completed_by': null})
        .eq('id', itemId);
  }

  Future<void> deleteItem(String itemId) async {
    await _client.from('shopping_items').delete().eq('id', itemId);
  }

  Future<void> clearCompleted(String householdId) async {
    await _client.rpc(
      'clear_completed_shopping_items',
      params: {'p_household_id': householdId},
    );
  }

  static String? validateName(String name) {
    if (name.trim().isEmpty) return 'Item name cannot be blank';
    return null;
  }
}
