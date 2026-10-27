import 'package:flutter/material.dart';
import 'package:household_os/features/expenses/domain/cancellation_preview.dart';
import 'package:household_os/features/expenses/domain/money.dart';

/// What the user chose in the cancel dialog; [reason] is null when left blank.
class CancelDecision {
  const CancelDecision(this.reason);
  final String? reason;
}

String _describe(int cents, String currency) {
  if (cents == 0) return 'settled';
  final amount = Money.format(cents.abs(), currency);
  return cents > 0 ? 'owed $amount' : 'owes $amount';
}

/// Confirms cancelling an expense or payment. Returns null if dismissed.
Future<CancelDecision?> showCancelFinancialDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required List<BalanceChange> changes,
  required String currentUserId,
  String currency = 'EUR',
  bool isExpense = true,
}) {
  return showDialog<CancelDecision>(
    context: context,
    builder: (_) => _CancelDialog(
      title: title,
      confirmLabel: confirmLabel,
      changes: changes,
      currentUserId: currentUserId,
      currency: currency,
      isExpense: isExpense,
    ),
  );
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog({
    required this.title,
    required this.confirmLabel,
    required this.changes,
    required this.currentUserId,
    required this.currency,
    required this.isExpense,
  });

  final String title;
  final String confirmLabel;
  final List<BalanceChange> changes;
  final String currentUserId;
  final String currency;
  final bool isExpense;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String _line(BalanceChange change) {
    final who = change.userId == widget.currentUserId
        ? 'You'
        : change.displayName;
    final before = _describe(change.beforeCents, widget.currency);
    final after = _describe(change.afterCents, widget.currency);
    final flag = change.reversesSign ? ' (reversed)' : '';
    return '$who: $before → $after$flag';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isExpense
                  ? 'This removes the expense from the balance. Payments '
                        'already recorded are not cancelled, so balances may '
                        'change in unexpected ways.'
                  : 'This removes the payment from the balance. It stays in '
                        'the cancelled history.',
            ),
            if (widget.changes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Balance changes', style: textTheme.titleSmall),
              for (final change in widget.changes)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _line(change),
                    style: change.reversesSign
                        ? textTheme.bodyMedium?.copyWith(
                            color: colorScheme.error,
                          )
                        : textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Based on what is loaded now; the final balance may differ.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _reasonController,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep'),
        ),
        FilledButton(
          onPressed: () {
            final reason = _reasonController.text.trim();
            Navigator.of(
              context,
            ).pop(CancelDecision(reason.isEmpty ? null : reason));
          },
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
