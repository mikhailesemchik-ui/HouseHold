import 'package:flutter/foundation.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

@immutable
class MemberBalance {
  const MemberBalance({
    required this.userId,
    required this.displayName,
    required this.netCents,
  });

  final String userId;
  final String displayName;

  /// Positive = others owe this member; negative = this member owes others.
  final int netCents;
}

@immutable
class PairwiseDebt {
  const PairwiseDebt({
    required this.fromUserId,
    required this.fromName,
    required this.toUserId,
    required this.toName,
    required this.amountCents,
  });

  final String fromUserId;
  final String fromName;
  final String toUserId;
  final String toName;

  /// Always positive.
  final int amountCents;
}

/// Calculates net balance per member from expenses and settlements.
///
/// For expenses: payer receives full credit; each participant is debited their share.
/// For settlements: from_user paid to_user, so from_user gains credit and to_user
/// loses credit by the same amount.
Map<String, MemberBalance> calculateNetBalances(
  List<Expense> expenses,
  List<Settlement> settlements,
) {
  final netCents = <String, int>{};
  final names = <String, String>{};

  for (final expense in expenses) {
    netCents.update(
      expense.paidBy,
      (v) => v + expense.amountCents,
      ifAbsent: () => expense.amountCents,
    );
    names[expense.paidBy] = expense.paidByDisplayName;

    for (final p in expense.participants) {
      netCents.update(
        p.userId,
        (v) => v - p.shareCents,
        ifAbsent: () => -p.shareCents,
      );
      names[p.userId] = p.displayName;
    }
  }

  for (final s in settlements) {
    netCents.update(
      s.fromUserId,
      (v) => v + s.amountCents,
      ifAbsent: () => s.amountCents,
    );
    names[s.fromUserId] = s.fromName;
    netCents.update(
      s.toUserId,
      (v) => v - s.amountCents,
      ifAbsent: () => -s.amountCents,
    );
    names[s.toUserId] = s.toName;
  }

  return {
    for (final entry in netCents.entries)
      entry.key: MemberBalance(
        userId: entry.key,
        displayName: names[entry.key] ?? 'Deleted member',
        netCents: entry.value,
      ),
  };
}

/// Produces a minimal list of pairwise debts that settle all balances.
/// Uses a greedy matching of largest creditors against largest debtors.
List<PairwiseDebt> simplifyDebts(Map<String, MemberBalance> balances) {
  // Mutable credit/debit pools (all positive values)
  final creditPool = <String, int>{};
  final debtPool = <String, int>{};
  final names = <String, String>{};

  for (final b in balances.values) {
    names[b.userId] = b.displayName;
    if (b.netCents > 0) creditPool[b.userId] = b.netCents;
    if (b.netCents < 0) debtPool[b.userId] = -b.netCents;
  }

  final creditors = creditPool.keys.toList()
    ..sort((a, b) => creditPool[b]!.compareTo(creditPool[a]!));
  final debtors = debtPool.keys.toList()
    ..sort((a, b) => debtPool[b]!.compareTo(debtPool[a]!));

  final debts = <PairwiseDebt>[];
  var ci = 0;
  var di = 0;

  while (ci < creditors.length && di < debtors.length) {
    final creditorId = creditors[ci];
    final debtorId = debtors[di];
    final credit = creditPool[creditorId]!;
    final debt = debtPool[debtorId]!;
    final amount = credit < debt ? credit : debt;

    debts.add(
      PairwiseDebt(
        fromUserId: debtorId,
        fromName: names[debtorId]!,
        toUserId: creditorId,
        toName: names[creditorId]!,
        amountCents: amount,
      ),
    );

    creditPool[creditorId] = credit - amount;
    debtPool[debtorId] = debt - amount;

    if (creditPool[creditorId] == 0) ci++;
    if (debtPool[debtorId] == 0) di++;
  }

  return debts;
}
