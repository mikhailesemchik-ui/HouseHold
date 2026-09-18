import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_pressable_scale.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/features/expenses/domain/balance.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';
import 'package:household_os/features/expenses/presentation/add_expense_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_provider.dart';
import 'package:household_os/features/expenses/presentation/record_settlement_screen.dart';
import 'package:household_os/features/expenses/presentation/widgets/balance_block.dart';
import 'package:household_os/features/expenses/presentation/widgets/history_row.dart';

/// One coherent financial surface: balance state → primary/secondary actions
/// → merged chronological history. Answers "are we settled, who owes whom,
/// what happened recently, how do I add an expense or record a repayment"
/// without ever computing a balance from partial data (see [_ExpensesBody]).
class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key, required this.householdId});

  final String householdId;

  void _openExpenseForm(BuildContext context) {
    // Root navigator + fullscreenDialog, same as the Task Form: the form
    // sits above the shell entirely, with its own Scaffold owning keyboard
    // resize. See `add_expense_screen.dart`.
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ExpenseFormScreen(householdId: householdId),
      ),
    );
  }

  void _openSettlementForm(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SettlementFormScreen(householdId: householdId),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expensesAsync = ref.watch(expensesProvider(householdId));
    final settlementsAsync = ref.watch(settlementsProvider(householdId));
    final currentUserId = ref.watch(currentUserIdProvider);

    return Scaffold(
      body: _ExpensesBody(
        householdId: householdId,
        expensesAsync: expensesAsync,
        settlementsAsync: settlementsAsync,
        currentUserId: currentUserId,
        onAddExpense: () => _openExpenseForm(context),
        onRecordSettlement: () => _openSettlementForm(context),
      ),
    );
  }
}

class _ExpensesBody extends ConsumerWidget {
  const _ExpensesBody({
    required this.householdId,
    required this.expensesAsync,
    required this.settlementsAsync,
    required this.currentUserId,
    required this.onAddExpense,
    required this.onRecordSettlement,
  });

  final String householdId;
  final AsyncValue<List<Expense>> expensesAsync;
  final AsyncValue<List<Settlement>> settlementsAsync;
  final String currentUserId;
  final VoidCallback onAddExpense;
  final VoidCallback onRecordSettlement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — every branch below places it as the first item of its
    // own scrollable, so it scrolls away with the page and returns
    // naturally at the top.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Expenses',
    );

    // Both streams are required for a correct balance. Previously a
    // settlements load failure was swallowed to an empty list, letting the
    // screen render a confidently wrong settled/debt state — a household's
    // financial state must never be computed from partial data. The
    // decision itself lives in `resolveExpensesLoadState`, a pure function,
    // so this exact correctness rule is unit-testable without a real
    // provider/stream.
    switch (resolveExpensesLoadState(expensesAsync, settlementsAsync)) {
      case ExpensesLoadState.loading:
        return SafeArea(
          bottom: false,
          child: ListView(
            children: const [
              header,
              AppSkeletonList(sectionCounts: {'': 5}, scrollable: false),
            ],
          ),
        );
      case ExpensesLoadState.expensesError:
        return SafeArea(
          bottom: false,
          child: ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load expenses. Please try again.',
                onRetry: () => ref.invalidate(expensesProvider(householdId)),
              ),
            ],
          ),
        );
      case ExpensesLoadState.settlementsError:
        return SafeArea(
          bottom: false,
          child: ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load payment history. Please try again.',
                onRetry: () => ref.invalidate(settlementsProvider(householdId)),
              ),
            ],
          ),
        );
      case ExpensesLoadState.ready:
        break;
    }

    final expenses = expensesAsync.requireValue;
    final settlements = settlementsAsync.requireValue;
    final debts = simplifyDebts(calculateNetBalances(expenses, settlements));
    final items = _mergedHistory(expenses, settlements);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: context.shellBottomInset + AppSpacing.base,
        ),
        children: [
          header,
          BalanceBlock(debts: debts, currentUserId: currentUserId),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.base,
              AppSpacing.sm,
              AppSpacing.base,
              AppSpacing.base,
            ),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                AppPressableScale(
                  child: FilledButton.icon(
                    onPressed: onAddExpense,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add expense'),
                  ),
                ),
                OutlinedButton(
                  onPressed: onRecordSettlement,
                  child: const Text('Record settlement'),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            const AppEmptyState(title: 'No expenses yet')
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.base,
                AppSpacing.lg,
                AppSpacing.base,
                AppSpacing.xs,
              ),
              child: Text(
                'History',
                style: Theme.of(context).textTheme.eyebrow?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final item in items)
              if (item is Expense)
                ExpenseHistoryRow(expense: item, currentUserId: currentUserId)
              else
                SettlementHistoryRow(
                  settlement: item as Settlement,
                  currentUserId: currentUserId,
                ),
          ],
        ],
      ),
    );
  }
}

/// Which body the Expenses screen should render given the current state of
/// both required financial streams. A pure decision, deliberately separate
/// from the widget that acts on it, so the correctness rule it encodes —
/// never compute a balance from partial data — is unit-testable without a
/// real provider or stream.
enum ExpensesLoadState { loading, expensesError, settlementsError, ready }

ExpensesLoadState resolveExpensesLoadState(
  AsyncValue<List<Expense>> expensesAsync,
  AsyncValue<List<Settlement>> settlementsAsync,
) {
  if (expensesAsync.isLoading || settlementsAsync.isLoading) {
    return ExpensesLoadState.loading;
  }
  if (expensesAsync.hasError) return ExpensesLoadState.expensesError;
  if (settlementsAsync.hasError) return ExpensesLoadState.settlementsError;
  return ExpensesLoadState.ready;
}

/// Merges expenses and settlements into one chronological feed from data the
/// providers already expose — no new query. Sorted by `createdAt` descending;
/// ties broken by `id` descending, since these are the only two fields both
/// row types share, for deterministic (not merely date-equal) ordering.
List<Object> _mergedHistory(
  List<Expense> expenses,
  List<Settlement> settlements,
) {
  final items = <Object>[...expenses, ...settlements];
  items.sort((a, b) {
    final aDate = a is Expense ? a.createdAt : (a as Settlement).createdAt;
    final bDate = b is Expense ? b.createdAt : (b as Settlement).createdAt;
    final cmp = bDate.compareTo(aDate);
    if (cmp != 0) return cmp;
    final aId = a is Expense ? a.id : (a as Settlement).id;
    final bId = b is Expense ? b.id : (b as Settlement).id;
    return bId.compareTo(aId);
  });
  return items;
}
