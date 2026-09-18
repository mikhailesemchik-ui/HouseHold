/// Corner radii used across the app. Anything else is a sign the surface
/// belongs to one of these categories already. (The Shopping composer's 22
/// is a deliberate, documented one-off, not a extra token.)
abstract final class AppRadius {
  /// Icon containers, chips, small inline surfaces.
  static const double sm = 8.0;

  /// Content cards, buttons, input fields. The default.
  static const double md = 12.0;

  /// Functional layer: glass navigation, sheets, dialogs.
  static const double lg = 16.0;

  /// "Soft card" radius: Dashboard tiles and every other card-family surface
  /// that lifts off the ground with a shadow rather than a hairline
  /// (`docs/new_design` visual pivot). Bumped from the original 18 — its
  /// only consumers were already card surfaces, not shared with the form
  /// controls that `sm`/`md`/`lg` serve, so this bump is targeted, not a
  /// cascade.
  static const double xl = 24.0;

  /// Outer *grouping* container radius — a surface that holds several inner
  /// soft-card rows (e.g. Profile's Notifications/Widget group). Kept
  /// distinct from `xl` so a group and the row-cards inside it read as two
  /// different radii, not one value nested inside itself.
  static const double group = 20.0;
}
