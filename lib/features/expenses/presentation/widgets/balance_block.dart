import 'package:flutter/material.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_money_text.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/expenses/domain/balance.dart';
import 'package:household_os/features/expenses/domain/money.dart';

/// Answers "are we settled, and if not, who owes whom" — the first thing
/// this screen must communicate.
///
/// [debts] is the household's full, authoritative simplified-debt list
/// (`simplifyDebts` output) and is shown in full: the household is only
/// "settled" when this list is empty, not merely when [currentUserId] has no
/// personal debt. A debt between two other household members is real
/// household state and must remain visible — this widget only reorders and
/// re-styles the authoritative list for emphasis; it never filters it.
class BalanceBlock extends StatelessWidget {
  const BalanceBlock({
    super.key,
    required this.debts,
    required this.currentUserId,
  });

  final List<PairwiseDebt> debts;
  final String currentUserId;

  @override
  Widget build(BuildContext context) {
    if (debts.isEmpty) {
      return const _SettledRow();
    }

    bool touchesCurrentUser(PairwiseDebt d) =>
        d.fromUserId == currentUserId || d.toUserId == currentUserId;

    // Presentation-only grouping and ordering: the underlying relationships
    // and amounts are exactly what `simplifyDebts` returned — only display
    // order and emphasis change. The current user's own debts lead (largest
    // first); everyone else's debts follow, also largest first.
    final personal = debts.where(touchesCurrentUser).toList()
      ..sort((a, b) => b.amountCents.compareTo(a.amountCents));
    final other = debts.where((d) => !touchesCurrentUser(d)).toList()
      ..sort((a, b) => b.amountCents.compareTo(a.amountCents));

    return _DebtBlock(
      personal: personal,
      other: other,
      currentUserId: currentUserId,
    );
  }
}

/// cents → "3 euros and 50 cents" for TalkBack, since a raw "€3.50" string is
/// read symbol-by-symbol rather than as a spoken amount. Presentation-only;
/// does not replace `Money.format`, which still owns the visible text.
String _spokenAmount(int cents) {
  final whole = cents ~/ 100;
  final frac = cents % 100;
  final wholeWord = whole == 1 ? '1 euro' : '$whole euros';
  if (frac == 0) return wholeWord;
  final fracWord = frac == 1 ? '1 cent' : '$frac cents';
  return '$wholeWord and $fracWord';
}

class _SettledRow extends StatelessWidget {
  const _SettledRow();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.base,
        AppSpacing.sm,
        AppSpacing.base,
        AppSpacing.sm,
      ),
      child: AppSoftCard(
        child: Semantics(
          label: 'You are settled up',
          excludeSemantics: true,
          container: true,
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outlined,
                color: colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'You are settled up',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The household's full debt state. When [personal] is non-empty its first
/// entry is the emphasized hero line; everything else (further personal
/// debts, and every debt between other members) renders compact below. When
/// [personal] is empty — the current user has no debt of their own, but the
/// household is not fully settled — there is no hero line and no "settled"
/// claim; a quiet label introduces the household's remaining balances
/// instead.
class _DebtBlock extends StatelessWidget {
  const _DebtBlock({
    required this.personal,
    required this.other,
    required this.currentUserId,
  });

  final List<PairwiseDebt> personal;
  final List<PairwiseDebt> other;
  final String currentUserId;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasPersonal = personal.isNotEmpty;
    final compactPersonal = hasPersonal ? personal.skip(1).toList() : personal;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.sm,
      ),
      // Stays tonal — never the white `AppSoftCard` fill, so it remains
      // visually distinct from the settled/history cards — but now carries
      // the same restrained soft shadow as every other card-family surface
      // (`docs/new_design`; matches Statistics' rotation-suggestion block).
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          shadows: AppShadows.card,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasPersonal)
                _DebtLine(
                  debt: personal.first,
                  currentUserId: currentUserId,
                  tier: _DebtLineTier.emphasized,
                )
              else
                Text(
                  'Household balances',
                  style: textTheme.eyebrow?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              for (final d in compactPersonal) ...[
                const SizedBox(height: AppSpacing.sm),
                _DebtLine(
                  debt: d,
                  currentUserId: currentUserId,
                  tier: _DebtLineTier.personalCompact,
                ),
              ],
              if (other.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.sm),
                for (final d in other)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: _DebtLine(
                      debt: d,
                      currentUserId: currentUserId,
                      tier: _DebtLineTier.otherQuiet,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _DebtLineTier {
  /// The single dominant relationship line: large type, current user always
  /// on one side.
  emphasized,

  /// A further debt of the current user's own, shown compactly.
  personalCompact,

  /// A debt between two other household members — real household state,
  /// shown quieter than personal debts, distinguished by wording (both
  /// people are named; neither is "you"), never by color alone.
  otherQuiet,
}

class _DebtLine extends StatelessWidget {
  const _DebtLine({
    required this.debt,
    required this.currentUserId,
    required this.tier,
  });

  final PairwiseDebt debt;
  final String currentUserId;
  final _DebtLineTier tier;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final involvesCurrentUser =
        debt.fromUserId == currentUserId || debt.toUserId == currentUserId;
    final isOwedToCurrentUser = debt.toUserId == currentUserId;

    final String relationship;
    if (!involvesCurrentUser) {
      relationship = '${debt.fromName} owes ${debt.toName}';
    } else if (isOwedToCurrentUser) {
      relationship = '${debt.fromName} owes you';
    } else {
      relationship = 'You owe ${debt.toName}';
    }

    // Calm, non-alarming colour in every direction — owing a housemate is
    // not an error state, so no tier uses `colorScheme.error`. Debts that
    // don't involve the current user are visually quieter (tertiary/muted),
    // which is the "quieter treatment" the design calls for — wording is
    // still what actually distinguishes the relationship, never color alone.
    final Color amountColor;
    if (!involvesCurrentUser) {
      amountColor = colorScheme.onSurfaceVariant;
    } else if (isOwedToCurrentUser) {
      amountColor = colorScheme.primary;
    } else {
      amountColor = colorScheme.onSurface;
    }

    final formatted = Money.format(debt.amountCents, 'EUR');
    final semanticSentence = '$relationship ${_spokenAmount(debt.amountCents)}';

    if (tier == _DebtLineTier.emphasized) {
      return Semantics(
        label: semanticSentence,
        excludeSemantics: true,
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              relationship,
              style: textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            AppMoneyText(
              formatted,
              style: textTheme.heroNumber?.copyWith(
                fontSize: 34,
                color: amountColor,
              ),
            ),
          ],
        ),
      );
    }

    final rowStyle = tier == _DebtLineTier.otherQuiet
        ? textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)
        : textTheme.bodyMedium;

    return Semantics(
      label: semanticSentence,
      excludeSemantics: true,
      container: true,
      child: Row(
        children: [
          Expanded(
            child: Text(
              relationship,
              style: rowStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          AppMoneyText(
            formatted,
            style: rowStyle?.copyWith(
              fontWeight: FontWeight.w600,
              color: amountColor,
            ),
          ),
        ],
      ),
    );
  }
}
