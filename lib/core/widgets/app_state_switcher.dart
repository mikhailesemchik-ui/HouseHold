import 'package:flutter/material.dart';

/// A coarse loading/empty/content screen-state switch (Motion Pass).
///
/// Callers key by state *category* (e.g. `'loading'`, `'empty'`, `'data'`),
/// never by the data itself — so a realtime update that keeps the screen in
/// the same category (e.g. one more item in an already non-empty list)
/// never re-triggers the transition. Only a coarse boundary crossing does.
class AppStateSwitcher extends StatelessWidget {
  const AppStateSwitcher({
    super.key,
    required this.stateKey,
    required this.child,
  });

  final String stateKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => Transform.translate(
            // Coarse state change only — a small settle-in, not a slide.
            offset: Offset(0, (1 - animation.value) * 6),
            child: child,
          ),
        ),
      ),
      child: KeyedSubtree(key: ValueKey(stateKey), child: child),
    );
  }
}
