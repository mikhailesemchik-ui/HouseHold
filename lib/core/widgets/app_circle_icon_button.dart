import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:household_os/core/theme/app_glass.dart';

/// A circular Telegram-frosted-glass button — the back/trailing-action chip
/// used across the app wherever a round chrome control sits in a header.
/// Same material family as the bottom nav (`AppGlass`), different form
/// factor.
class AppCircleIconButton extends StatelessWidget {
  const AppCircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;

  static const _diameter = 48.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const shape = CircleBorder(
      side: BorderSide(color: AppGlass.rimColor, width: AppGlass.rimWidth),
    );

    return DecoratedBox(
      decoration: const ShapeDecoration(
        shape: shape,
        shadows: AppGlass.shadows,
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: AppGlass.blurSigma,
            sigmaY: AppGlass.blurSigma,
          ),
          child: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: AppGlass.fill),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0.0, 0.45],
                      colors: [
                        Colors.white.withValues(alpha: AppGlass.highlightPeak),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: _diameter,
                  height: _diameter,
                  child: IconButton(
                    icon: Icon(icon),
                    onPressed: onPressed,
                    tooltip: tooltip,
                    color: colorScheme.onSurface,
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
