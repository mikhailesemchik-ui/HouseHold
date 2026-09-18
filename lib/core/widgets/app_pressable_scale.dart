import 'package:flutter/material.dart';

/// Restrained press-down feedback for large filled CTAs (e.g. "New home",
/// "Add task", "Add expense") — Motion Pass.
///
/// Wraps the button without intercepting its gestures: [Listener] only
/// observes raw pointer events (it defers hit-testing to its child), so the
/// wrapped button's own `onPressed`, ink, semantics, and hit target are
/// completely unaffected. Purely a visual scale, driven by pointer state.
class AppPressableScale extends StatefulWidget {
  const AppPressableScale({super.key, required this.child});

  final Widget child;

  @override
  State<AppPressableScale> createState() => _AppPressableScaleState();
}

class _AppPressableScaleState extends State<AppPressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: reduceMotion
            ? Duration.zero
            : Duration(milliseconds: _pressed ? 100 : 140),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
