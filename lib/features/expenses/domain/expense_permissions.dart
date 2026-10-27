import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

/// Who may rename an expense: its creator, its payer, a participant or the
/// household owner. Mirrors the `expenses_update_authorized` policy; the
/// database is the real boundary, this only decides which controls to show.
bool canEditExpenseTitle(
  Expense expense,
  String currentUserId, {
  required bool isOwner,
}) {
  if (currentUserId.isEmpty) return false;
  return isOwner ||
      expense.createdBy == currentUserId ||
      expense.paidBy == currentUserId ||
      expense.participants.any((p) => p.userId == currentUserId);
}

/// Who may delete an expense: its creator, its payer or the household owner.
/// Mirrors the `expenses_delete_authorized` policy.
bool canDeleteExpense(
  Expense expense,
  String currentUserId, {
  required bool isOwner,
}) {
  if (currentUserId.isEmpty) return false;
  return isOwner ||
      expense.createdBy == currentUserId ||
      expense.paidBy == currentUserId;
}

/// Mirrors the server rule: sender, recipient, original creator or owner.
bool canCancelSettlement(
  Settlement settlement,
  String currentUserId, {
  required bool isOwner,
}) {
  if (currentUserId.isEmpty) return false;
  return isOwner ||
      settlement.createdBy == currentUserId ||
      settlement.fromUserId == currentUserId ||
      settlement.toUserId == currentUserId;
}
