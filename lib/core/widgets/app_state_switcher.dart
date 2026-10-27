import 'package:flutter/material.dart';

/// A coarse loading/empty/content screen-state switch (Motion Pass).
///
/// Callers key by state *category* (e.g. `'loading'`, `'empty'`, `'data'`),
/// never by the data itself — so a realtime update that keeps the screen in
/// the same category (e.g. one more item in an already non-empty list)
/// never re-triggers the transition. Only a coarse boundary crossing does.
///
/// On iOS the swap out of `'loading'` is instant. Screens put their header
/// inside the switched subtree, so cross-fading would draw two headers over
/// each other and nudge the new one up 6dp — exactly while the page is still
/// sliding in, where it reads as the header jumping.
class AppStateSwitcher extends StatefulWidget {
  const AppStateSwitcher({
    super.key,
    required this.stateKey,
    required this.child,
  });

  final String stateKey;
  final Widget child;

  @override
  State<AppStateSwitcher> createState() => _AppStateSwitcherState();
}

class _AppStateSwitcherState extends State<AppStateSwitcher> {
  bool _leftLoading = false;

  @override
  void didUpdateWidget(covariant AppStateSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stateKey != widget.stateKey) {
      _leftLoading = oldWidget.stateKey == 'loading';
    }
  }

  @override
  Widget build(BuildContext context) {
    final skipForIos =
        _leftLoading && Theme.of(context).platform == TargetPlatform.iOS;
    final duration = MediaQuery.disableAnimationsOf(context) || skipForIos
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) {
        // The outgoing 'loading' subtree keeps its own 200ms controller, so
        // hide it outright instead of letting it fade out under the new one.
        if (skipForIos && child.key == const ValueKey('loading')) {
          return const SizedBox.shrink();
        }
        return FadeTransition(
          opacity: animation,
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, _) => Transform.translate(
              // Coarse state change only — a small settle-in, not a slide.
              offset: Offset(0, (1 - animation.value) * 6),
              child: child,
            ),
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(widget.stateKey), child: widget.child),
    );
  }
}
