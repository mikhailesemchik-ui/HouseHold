import 'package:flutter/material.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_money_text.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/expenses/data/expense_repository.dart';
import 'package:household_os/features/expenses/domain/expense.dart';
import 'package:household_os/features/expenses/domain/money.dart';
import 'package:household_os/features/expenses/domain/settlement.dart';

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return 'Today';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day) {
    return 'Yesterday';
  }
  const months = [
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${local.day} ${months[local.month]}';
}

// ---------------------------------------------------------------------------
// Expense row — an individual soft card (`docs/new_design` family).
// Distinguished from a settlement row by icon + wording + structure, never
// colour alone.
// ---------------------------------------------------------------------------

class ExpenseHistoryRow extends StatelessWidget {
  const ExpenseHistoryRow({
    super.key,
    required this.expense,
    required this.currentUserId,
  });

  final Expense expense;
  final String currentUserId;

  Future<void> _delete(BuildContext context) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete expense?',
      message: 'This cannot be undone.',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ExpenseRepository(supabaseClient).deleteExpense(expense.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete expense.')),
        );
      }
    }
  }

  void _editTitle(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _EditExpenseTitleDialog(expense: expense),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final formatted = Money.format(expense.amountCents, expense.currency);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        0,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        child: Row(
          children: [
            Icon(
              Icons.receipt_long_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              // One combined announcement ("Groceries, paid by Alice,
              // Today, €25.00") rather than title/subtitle/amount as three
              // unrelated fragments a screen-reader user has to swipe
              // between and mentally reassemble.
              child: Semantics(
                label:
                    '${expense.title}, paid by ${expense.paidByDisplayName}, '
                    '${_formatDate(expense.createdAt)}, $formatted',
                excludeSemantics: true,
                container: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      expense.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    Text(
                      '${expense.paidByDisplayName} · ${_formatDate(expense.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            ExcludeSemantics(
              child: AppMoneyText(
                formatted,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Expense actions',
              icon: Icon(
                Icons.more_vert_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
              onSelected: (value) {
                if (value == 'edit') _editTitle(context);
                if (value == 'delete') _delete(context);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit title')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settlement row — same row shape, deliberately different icon/wording so a
// scanning glance (or a screen reader) never has to rely on colour to tell
// the two apart.
// ---------------------------------------------------------------------------

class SettlementHistoryRow extends StatelessWidget {
  const SettlementHistoryRow({
    super.key,
    required this.settlement,
    required this.currentUserId,
  });

  final Settlement settlement;
  final String currentUserId;

  Future<void> _delete(BuildContext context) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete payment record?',
      message: 'This cannot be undone.',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ExpenseRepository(supabaseClient).deleteSettlement(settlement.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete payment record.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canDelete = settlement.createdBy == currentUserId;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final formatted = Money.format(settlement.amountCents, settlement.currency);
    final dateText = _formatDate(settlement.createdAt);

    final subtitleText = settlement.note != null
        ? '$dateText · ${settlement.note}'
        : dateText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        0,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        child: Row(
          children: [
            Icon(Icons.handshake_rounded, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              // One combined "who paid whom, how much" announcement, e.g.
              // "Bob paid Alice, 10 euros" — never split across separate
              // nodes.
              child: Semantics(
                label:
                    '${settlement.fromName} paid ${settlement.toName}, $formatted',
                excludeSemantics: true,
                container: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${settlement.fromName} paid ${settlement.toName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    Text(
                      subtitleText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            ExcludeSemantics(
              child: AppMoneyText(
                formatted,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (canDelete)
              PopupMenuButton<String>(
                tooltip: 'Settlement actions',
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
                onSelected: (value) {
                  if (value == 'delete') _delete(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit expense title — unchanged behaviour, 1 field, appropriately a dialog.
// ---------------------------------------------------------------------------

class _EditExpenseTitleDialog extends StatefulWidget {
  const _EditExpenseTitleDialog({required this.expense});

  final Expense expense;

  @override
  State<_EditExpenseTitleDialog> createState() =>
      _EditExpenseTitleDialogState();
}

class _EditExpenseTitleDialogState extends State<_EditExpenseTitleDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.expense.title);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = _controller.text;
    final error = ExpenseRepository.validateTitle(title);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    if (_isSubmitting) return;
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    try {
      await ExpenseRepository(
        supabaseClient,
      ).updateExpenseTitle(expenseId: widget.expense.id, title: title);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update expense.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit title'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: 'Title', errorText: _error),
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
