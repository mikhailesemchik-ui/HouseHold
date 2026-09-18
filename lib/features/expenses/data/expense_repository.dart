import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

class ExpenseRepository {
  const ExpenseRepository(this._client);

  final SupabaseClient _client;

  /// Streams expenses for [householdId] via Supabase Realtime.
  /// Fetches participants in a single batch query on each emission.
  Stream<List<Expense>> watchExpenses(String householdId) {
    return _client
        .from('expenses')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('created_at', ascending: false)
        .asyncMap((rows) async {
          if (rows.isEmpty) return [];

          final ids = rows.map((r) => r['id'] as String).toList();

          final participantRows = await _client
              .from('expense_participants')
              .select()
              .inFilter('expense_id', ids);

          final byExpense = <String, List<ExpenseParticipant>>{};
          for (final pr in participantRows) {
            final p = ExpenseParticipant.fromMap(pr);
            byExpense.putIfAbsent(p.expenseId, () => []).add(p);
          }

          return rows.map((r) {
            return Expense.fromMap(r, byExpense[r['id']] ?? []);
          }).toList();
        });
  }

  Future<void> createEqualSplitExpense({
    required String householdId,
    required String title,
    required int amountCents,
    required String currency,
    required String paidBy,
    required List<String> participantIds,
  }) async {
    await _client.rpc(
      'create_equal_split_expense',
      params: {
        'p_household_id': householdId,
        'p_title': title,
        'p_amount_cents': amountCents,
        'p_currency': currency,
        'p_paid_by': paidBy,
        'p_participant_ids': participantIds,
      },
    );
  }

  Future<void> updateExpenseTitle({
    required String expenseId,
    required String title,
  }) async {
    await _client
        .from('expenses')
        .update({'title': title.trim()})
        .eq('id', expenseId);
  }

  Future<void> deleteExpense(String expenseId) async {
    await _client.from('expenses').delete().eq('id', expenseId);
  }

  Future<List<ExpenseMember>> fetchMembers(String householdId) async {
    final rows = await _client
        .from('household_members')
        .select('user_id, profiles(display_name)')
        .eq('household_id', householdId)
        .eq('status', 'active');
    return rows.map((r) => ExpenseMember.fromMap(r)).toList();
  }

  Stream<List<Settlement>> watchSettlements(String householdId) {
    return _client
        .from('expense_settlements')
        .stream(primaryKey: ['id'])
        .eq('household_id', householdId)
        .order('created_at', ascending: false)
        .map((rows) => rows.map(Settlement.fromMap).toList());
  }

  Future<void> createSettlement({
    required String householdId,
    required String fromUserId,
    required String toUserId,
    required int amountCents,
    required String currency,
    String? note,
  }) async {
    await _client.rpc(
      'create_settlement',
      params: {
        'p_household_id': householdId,
        'p_from_user_id': fromUserId,
        'p_to_user_id': toUserId,
        'p_amount_cents': amountCents,
        'p_currency': currency,
        'p_note': note,
      },
    );
  }

  Future<void> deleteSettlement(String settlementId) async {
    await _client.from('expense_settlements').delete().eq('id', settlementId);
  }

  static String? validateTitle(String title) {
    if (title.trim().isEmpty) return 'Title cannot be blank';
    return null;
  }
}
