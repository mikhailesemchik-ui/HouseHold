import 'package:flutter/material.dart';

/// A title/name [Text] that eases its color when completion state changes,
/// shared by Tasks and Shopping rows (Motion Pass — calm microinteractions).
///
/// Only the color animates — the strike-through itself still snaps
/// instantly, so widget tests reading `Text.style?.decoration` see the
/// exact same value as the static implementation this replaces.
class AppCompletionTitle extends StatelessWidget {
  const AppCompletionTitle({
    super.key,
    required this.text,
    required this.completed,
    required this.baseStyle,
    required this.completedColor,
    this.maxLines,
  });

  final String text;
  final bool completed;
  final TextStyle? baseStyle;
  final Color completedColor;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final targetColor = completed ? completedColor : baseStyle?.color;

    return TweenAnimationBuilder<Color?>(
      duration: duration,
      curve: Curves.easeOutCubic,
      tween: ColorTween(end: targetColor),
      builder: (context, color, _) => Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: baseStyle?.copyWith(
          color: color,
          decoration: completed
              ? TextDecoration.lineThrough
              : TextDecoration.none,
        ),
      ),
    );
  }
}
