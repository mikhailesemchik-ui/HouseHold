import 'package:flutter/material.dart';
import 'package:household_os/core/widgets/app_circle_icon_button.dart';

/// The shared circular back button used as `AppBar.leading` on every screen
/// that can go back (`docs/new_design` visual pivot). `chevron_left_rounded`
/// matches the reference's bare-chevron glyph more closely than a full
/// arrow.
///
/// Calls `Navigator.maybePop`, exactly what Flutter's own default back
/// button does — this replaces the *paint*, not the pop behaviour.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AppCircleIconButton(
      icon: Icons.chevron_left_rounded,
      tooltip: 'Back',
      onPressed: () => Navigator.maybePop(context),
    );
  }
}

/// The circular frosted equivalent of [AppBackButton] for screens that pick
/// a close (not back) affordance — e.g. a form pushed as a
/// `fullscreenDialog`. Same `Navigator.maybePop` behaviour as Flutter's own
/// `CloseButton`, so it still triggers a screen's `PopScope`/dirty-state
/// guard exactly as before; only the paint changes.
class AppCloseButton extends StatelessWidget {
  const AppCloseButton({super.key});

  @override
  Widget build(BuildContext context) {
    return AppCircleIconButton(
      icon: Icons.close_rounded,
      tooltip: 'Close',
      onPressed: () => Navigator.maybePop(context),
    );
  }
}
