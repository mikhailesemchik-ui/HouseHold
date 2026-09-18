import 'package:flutter/material.dart';

/// Soft, diffuse drop shadows for the `docs/new_design` visual pivot.
///
/// Deliberately small: exactly the three surfaces the reference images show
/// a shadow on. Do not add a shadow to a surface the references don't show
/// one on — see the visual-pivot plan's Binding decisions.
abstract final class AppShadows {
  /// Dashboard tiles and every other individually-lifted "soft card" row.
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0F1A1A18), blurRadius: 16, offset: Offset(0, 6)),
  ];

  /// The floating glass navigation shell — one step stronger than a card,
  /// since it sits above scrolled content rather than beside other cards.
  static const List<BoxShadow> nav = [
    BoxShadow(color: Color(0x1A1A1A18), blurRadius: 24, offset: Offset(0, 10)),
  ];

  /// Primary CTA buttons (e.g. "New home"): a soft green-tinted glow rather
  /// than a neutral shadow, matching the reference's button treatment.
  static const List<BoxShadow> primaryCta = [
    BoxShadow(color: Color(0x401B6B48), blurRadius: 16, offset: Offset(0, 6)),
  ];

  /// The Shopping composer while focused (Motion Pass) — one step stronger
  /// than [card], the same delta [nav] uses over [card], so focus reads as
  /// "lifted" without inventing a new shadow language.
  static const List<BoxShadow> cardFocused = [
    BoxShadow(color: Color(0x151A1A18), blurRadius: 20, offset: Offset(0, 8)),
  ];
}
