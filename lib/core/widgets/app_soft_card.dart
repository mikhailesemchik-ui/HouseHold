import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// A soft, shadowed white surface — the `docs/new_design` replacement for a
/// bare row or a hairline-bordered tile. Not yet adopted by any screen
/// (that's Phases 2+); this is the primitive itself only.
///
/// `onTap` is optional: pass it for a tappable row/tile, omit it for a
/// purely decorative card.
class AppSoftCard extends StatelessWidget {
  const AppSoftCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.radius = AppRadius.xl,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(shape: shape, shadows: AppShadows.card),
      child: Material(
        color: colorScheme.surfaceBright,
        shape: shape,
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}
