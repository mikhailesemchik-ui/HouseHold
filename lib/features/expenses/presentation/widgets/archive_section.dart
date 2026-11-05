import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/expenses/domain/archived_entry.dart';
import 'package:household_os/features/expenses/domain/money.dart';

/// Collapsed, read-only list of cancelled entries.
class ArchiveSection extends StatelessWidget {
  const ArchiveSection({super.key, required this.entries});

  final List<ArchivedEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        AppSpacing.lg,
        AppSpacing.base,
        0,
      ),
      child: AppSoftCard(
        // Scoped to this tile: its header's ListTile ink would otherwise
        // flash a grey rectangle over the soft card on tap. Focus and hover
        // colours are left alone so keyboard focus stays visible.
        child: Theme(
          data: Theme.of(context).copyWith(
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: ExpansionTile(
            title: Text('Cancelled entries (${entries.length})'),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              for (final entry in entries) _row(entry, textTheme, muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ArchivedEntry entry, TextTheme textTheme, Color muted) {
    final kind = entry.isExpense ? 'Expense' : 'Payment';
    final amount = Money.format(entry.amountCents, entry.currency);
    final when = entry.canceledAt.toLocal().toString().substring(0, 16);
    final reason = entry.reason == null ? '' : ' · ${entry.reason}';
    return ListTile(
      dense: true,
      title: Text('$kind: ${entry.title} · $amount'),
      subtitle: Text(
        'Cancelled by ${entry.canceledByName} on $when$reason',
        style: textTheme.bodySmall?.copyWith(color: muted),
      ),
    );
  }
}
