import 'package:flutter/material.dart';

/// The approved Telegram-frosted glass material (from the bottom nav's
/// device-verified frosted-material pass), shared by round chrome controls
/// (back/overflow/invite buttons) so they belong to the same material
/// family as the nav. The nav itself (`app_router.dart`) keeps its own
/// frozen private constants unchanged — this holder is for the new
/// consumers only, not a refactor of the already-approved nav.
abstract final class AppGlass {
  static const double blurSigma = 28.0;
  // ~72% alpha — one step more transparent than the original ~76%
  // (0xC2FBFAF6), so backdrop/blur contribution reads more clearly.
  static const Color fill = Color(0xB8FBFAF6);
  static const double highlightPeak = 0.12;
  static const Color rimColor = Color(0x18000000);
  static const double rimWidth = 0.5;
  static const List<BoxShadow> shadows = [
    BoxShadow(color: Color(0x20000000), offset: Offset(0, 1), blurRadius: 6),
  ];
}
