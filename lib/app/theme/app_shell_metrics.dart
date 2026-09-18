import 'package:flutter/material.dart';

/// The glass bottom navigation's own content height, passed to the
/// `NavigationBar` inside `_GlassNavBar` in `app_router.dart`.
///
/// This is a **shell-internal rendering detail**. Feature screens must never
/// use it to compute their own bottom clearance — the shell already publishes
/// the measured result through `MediaQuery` (see [AppShellMetrics]).
const double kNavBarContentHeight = 80.0;

/// Clearance for a floating action button that sits above the shell's
/// navigation: 56dp FAB + 16dp margin. Describes the control, not the nav bar.
const double kFabClearance = 72.0;

extension AppShellMetrics on BuildContext {
  /// Space the shell's navigation occupies at the bottom of the current
  /// viewport — or, outside the shell, the device's own safe-area inset.
  ///
  /// Flutter measures this for us. The shell's `Scaffold(extendBody: true)`
  /// publishes the laid-out height of its `bottomNavigationBar` (including the
  /// safe area the bar consumes itself) as `MediaQuery.padding.bottom` for
  /// everything in its body, and drops it back to zero while the keyboard is
  /// open, because the body has already been resized above the keyboard.
  /// Never add [kNavBarContentHeight] on top of this value — that is the
  /// double-count this replaced.
  ///
  /// **Prefer not to use this at all.** A `ListView`/`ScrollView` with no
  /// explicit `padding` consumes `MediaQuery.padding` automatically and is
  /// always correct. Reach for this only where that cannot happen:
  ///
  ///  * `Positioned` children of a `Stack` (FABs, the Shopping composer)
  ///  * floating overlays outside the scroll view
  ///  * a scrollable that needs explicit padding for another reason
  ///    (horizontal insets, a top offset, or room for a floating control)
  double get shellBottomInset => MediaQuery.paddingOf(this).bottom;
}
