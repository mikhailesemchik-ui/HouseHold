import 'package:flutter/material.dart' show EdgeInsets;

/// Shared AppBar geometry for the `docs/new_design` visual pivot — one set
/// of constants reused by every screen's `AppBar` via the global theme,
/// rather than per-screen magic numbers.
abstract final class AppBarMetrics {
  /// Taller than the M3 default (56) to comfortably fit the bigger title
  /// and the 48dp circular leading/action buttons with breathing room.
  static const double toolbarHeight = 72.0;

  /// 8dp inset before the 48dp circular back button + 8dp gap after it,
  /// so the button never sits flush against the screen edge.
  static const double leadingWidth = 64.0;

  /// Gap between the leading button and the title (and, with no leading,
  /// the title's own left inset).
  static const double titleSpacing = 12.0;

  /// Trailing circular action buttons' own margin from the screen's right
  /// edge.
  static const actionsPadding = EdgeInsets.only(right: 8.0);
}
