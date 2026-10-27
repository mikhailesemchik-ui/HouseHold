import 'package:household_os/features/expenses/domain/balance.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

/// How one member's net balance moves if an entry is cancelled.
class BalanceChange {
  const BalanceChange({
    required this.userId,
    required this.displayName,
    required this.beforeCents,
    required this.afterCents,
  });

  final String userId;
  final String displayName;

  /// Positive: owed money. Negative: owes money.
  final int beforeCents;
  final int afterCents;

  bool get reversesSign =>
      (beforeCents > 0 && afterCents < 0) ||
      (beforeCents < 0 && afterCents > 0);
}

/// Members whose balance changes if the given expense or settlement is
/// cancelled, computed with the same [calculateNetBalances] the screen uses.
///
/// Empty when nothing changes or when records in another currency make a
/// combined balance meaningless. Based on the records currently loaded, so it
/// is an estimate, not a guarantee about the final server state.
List<BalanceChange> cancellationBalanceChanges({
  required List<Expense> expenses,
  required List<Settlement> settlements,
  String? expenseId,
  String? settlementId,
}) {
  if (hasForeignCurrency(expenses, settlements)) return const [];
  final before = calculateNetBalances(expenses, settlements);
  final after = calculateNetBalances(
    expenses.where((e) => e.id != expenseId).toList(),
    settlements.where((s) => s.id != settlementId).toList(),
  );
  final changes = <BalanceChange>[];
  for (final userId in {...before.keys, ...after.keys}) {
    final b = before[userId]?.netCents ?? 0;
    final a = after[userId]?.netCents ?? 0;
    if (a == b) continue;
    changes.add(
      BalanceChange(
        userId: userId,
        displayName: (before[userId] ?? after[userId])!.displayName,
        beforeCents: b,
        afterCents: a,
      ),
    );
  }
  changes.sort((x, y) => x.displayName.compareTo(y.displayName));
  return changes;
}
