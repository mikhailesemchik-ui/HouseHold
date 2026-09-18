import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A consistent recoverable-error state for lists and screens.
///
/// Replaces the bare `Center(child: Text('Could not load...'))` pattern that
/// was duplicated across most async screens with no retry affordance.
class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.alignment = Alignment.center,
  });

  /// User-facing message only — never a raw exception or backend error.
  final String message;
  final VoidCallback? onRetry;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 36,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.base),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
