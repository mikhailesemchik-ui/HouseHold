import 'package:flutter/material.dart';

/// A rounded-square ("squircle") icon container — the pastel icon chip used
/// on Dashboard tiles and Homes rows (`docs/new_design`). Shared because both
/// screens need the identical squircle geometry; each caller supplies its own
/// background/icon colors (Dashboard's `FeatureAccent`, Homes' primary tint).
///
/// Radius scales with size rather than using a fixed value, so a smaller
/// chip (e.g. a quiet tile's) still reads as a squircle, not a barely-rounded
/// square.
class AppIconChip extends StatelessWidget {
  const AppIconChip({
    super.key,
    required this.icon,
    required this.background,
    required this.foreground,
    this.size = 36,
    this.iconSize = 18,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.4),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: foreground),
    );
  }
}
