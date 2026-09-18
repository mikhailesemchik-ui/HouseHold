import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A single selectable member control, used by both the expense form
/// ("Paid by" / "Split between") and the settlement form ("From" / "To").
///
/// A compact, `Wrap`-friendly alternative to `DropdownButton` that scales to
/// long names and many members without horizontal clipping at large text —
/// deliberately not an avatar-bearing component; the app currently has no
/// avatar UI to reuse here, so this stays a plain name control.
///
/// Whether tapping toggles a single selection (payer, from/to) or a set
/// (participants) is entirely the caller's concern — this widget only knows
/// its own selected/unselected visual and semantic state.
class MemberOption extends StatelessWidget {
  const MemberOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: label,
      selected: selected,
      button: true,
      excludeSemantics: true,
      container: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: Material(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.12)
              : colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            side: BorderSide(
              color: selected ? colorScheme.primary : colorScheme.outline,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
