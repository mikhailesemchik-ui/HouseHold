import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

final currentUserIdProvider = Provider<String>((ref) {
  final id = supabaseClient.auth.currentUser?.id;
  // Anonymous-first: auth completes before this screen is reachable.
  assert(id != null, 'currentUserIdProvider: no authenticated user');
  return id ?? '';
});

/// autoDispose cancels the subscription when the screen is left.
final expensesProvider = StreamProvider.autoDispose
    .family<List<Expense>, String>((ref, householdId) {
      return ExpenseRepository(supabaseClient).watchExpenses(householdId);
    });

/// autoDispose cancels the subscription when the screen is left.
final settlementsProvider = StreamProvider.autoDispose
    .family<List<Settlement>, String>((ref, householdId) {
      return ExpenseRepository(supabaseClient).watchSettlements(householdId);
    });

final expenseMembersProvider = FutureProvider.autoDispose
    .family<List<ExpenseMember>, String>((ref, householdId) {
      return ExpenseRepository(supabaseClient).fetchMembers(householdId);
    });
