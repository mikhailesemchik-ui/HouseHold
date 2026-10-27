import 'package:flutter/material.dart';

/// Lets a form on iOS dismiss its keyboard by tapping empty space or
/// dragging the list.
///
/// Flutter deliberately does not unfocus on a touch outside a text field on
/// mobile, and the iOS decimal pad has no Return key, so without this the
/// keyboard of an amount field cannot be closed. Other platforms are left
/// exactly as they were.
class AppKeyboardDismiss extends StatelessWidget {
  const AppKeyboardDismiss({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return child;
    // Translucent so the tap reaches empty space, while buttons and fields
    // inside still win the gesture arena and handle their own taps.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}

/// Drag-to-dismiss for the form's scrollable, iOS only.
ScrollViewKeyboardDismissBehavior appKeyboardDismissBehavior(
  BuildContext context,
) => Theme.of(context).platform == TargetPlatform.iOS
    ? ScrollViewKeyboardDismissBehavior.onDrag
    : ScrollViewKeyboardDismissBehavior.manual;
