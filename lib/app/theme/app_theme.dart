import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:household_os/app/theme/app_bar_metrics.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_spacing.dart';

// Deep botanical green — brand accent. Kept as the ColorScheme *seed* only;
// the effective CTA/selected-primary color is the richer `_kPrimary` below.
const _kSeed = Color(0xFF3D7A5E);

// Richer primary: more saturated than the M3 auto-derived tone, ensuring
// FilledButton and other primary-surface widgets read as confident green.
const _kPrimary = Color(0xFF1B6B48);
const _kOnPrimary = Colors.white;

// Warm near-black — slight warm cast matches the surface palette.
const _kOnSurface = Color(0xFF1A1A18);

// Secondary text — meta lines, subtitles, and (via ColorScheme.outline, see
// below) hairline dividers and default outlines.
const _kSecondaryText = Color(0xFF5C5F55);

// Tertiary text — placeholders, eyebrow labels, disabled/tertiary metadata.
// Deliberately its own token rather than ColorScheme.tertiary: that slot is
// reserved for a genuine third accent hue, not a muted-text role.
const _kTertiaryText = Color(0xFF8D8F83);

// Navigation unselected: warm mid-gray with a subtle green cast.
const _kNavUnselected = Color(0xFF5E6B64);

// Warm neutral surfaces — slight green-grey cast, not pure white. Darkened
// twice from the original v3 values: the first pass (below the ground/tonal
// tokens) still read as too pale/monochrome on the physical device — white
// lifted surfaces and tonal blocks were legible only up close, not at a
// glance. This second, still-restrained step gives white content a real edge
// and keeps tonal content clearly between white and ground, without shadows,
// borders on bare rows, or darkening ink/accent/primary tokens.
const _kSurface = Color(0xFFECE8E0);

/// Flat fallback background for the few full-screen routes that render
/// outside the shell's `AppBackground` (Task/Expense/Settlement forms,
/// Startup) — pushed on the root `Navigator`, by existing design, so they
/// never see the shell-root gradient. Kept as the same tone `_kSurface` used
/// before the visual pivot, so these screens still read as a coherent warm
/// ground rather than falling through to nothing once `scaffoldBackgroundColor`
/// turns transparent app-wide.
const appFlatBackgroundFallback = _kSurface;
const _kTonalSurface = Color(0xFFE4DED3);
const _kSurfaceContainer = Color(0xFFDFD9D0);
const _kSurfaceContainerHigh = Color(0xFFD9D4CA);
const _kSurfaceContainerHighest = Color(0xFFD3CDC3);

// A real white surface — distinct from the warm ground — for content that
// intentionally lifts off it (dashboard tiles, dialogs, sheets). Not every
// row should use this; most content stays on the ground or the tonal
// surface above.
const _kSurfaceWhite = Color(0xFFFFFFFF);

// Divider / outline — one token for both. Hairlines, input borders, and
// OutlinedButton all read from this, via ColorScheme.outline being pinned to
// it below, so there is exactly one "line" color in the app. Darkened one
// step alongside the surfaces above so it stays a visible hairline against
// the new (also darker) ground rather than fading back to the same gap.
const _kDivider = Color(0xFFD6D2C7);

// A softer edge, reserved for white lifted surfaces that sit directly on the
// ground (Dashboard `_TileSurface`, `_StatisticsRow`) — visibly present but
// quieter than `_kDivider`, since those surfaces already separate from the
// ground by color and don't need as strong a line as an input border or a
// row divider does. Nudged darker alongside the ground above so the ring
// still reads as its own edge rather than nearly matching the (now deeper)
// ground behind it.
const _kOutlineVariant = Color(0xFFDFDACD);

// The resolved ColorScheme, built once so every themed component below (and
// InputDecorationTheme in particular, which needs `error`) shares the same
// values rather than each recomputing `ColorScheme.fromSeed(...)`.
final _kColorScheme = ColorScheme.fromSeed(seedColor: _kSeed).copyWith(
  primary: _kPrimary,
  onPrimary: _kOnPrimary,
  surface: _kSurface,
  onSurface: _kOnSurface,
  onSurfaceVariant: _kSecondaryText,
  outline: _kDivider,
  outlineVariant: _kOutlineVariant,
  surfaceBright: _kSurfaceWhite,
  surfaceContainerLow: _kTonalSurface,
  surfaceContainer: _kSurfaceContainer,
  surfaceContainerHigh: _kSurfaceContainerHigh,
  surfaceContainerHighest: _kSurfaceContainerHighest,
);

// ---------------------------------------------------------------------------
// Design tokens that have no home in ColorScheme.
//
// Kept in a ThemeExtension rather than as bare constants so a future dark
// theme can override them in one place instead of every call site.
// ---------------------------------------------------------------------------

/// An icon colour paired with the container it sits on.
@immutable
class FeatureAccent {
  const FeatureAccent({required this.icon, required this.container});

  final Color icon;
  final Color container;

  static FeatureAccent lerp(FeatureAccent a, FeatureAccent b, double t) {
    return FeatureAccent(
      icon: Color.lerp(a.icon, b.icon, t)!,
      container: Color.lerp(a.container, b.container, t)!,
    );
  }
}

/// Per-feature accents, functional-layer (glass) colours, and text tones that
/// don't map to a `ColorScheme` slot.
///
/// Accents are harmonized: every icon colour targets ~L*42 and every container
/// ~L*90, so hue differentiates the features while visual weight stays equal.
/// Use them **only** to tint icon containers — never row backgrounds, body
/// text, or borders.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.tasks,
    required this.shopping,
    required this.expenses,
    required this.members,
    required this.statistics,
    required this.glassFill,
    required this.glassHighlight,
    required this.textTertiary,
    required this.navUnselected,
    required this.navSelectedPill,
  });

  final FeatureAccent tasks;
  final FeatureAccent shopping;
  final FeatureAccent expenses;
  final FeatureAccent members;
  final FeatureAccent statistics;

  /// Translucent fill for the bottom navigation surface. Opaque enough to keep
  /// labels legible over any scrolled content.
  final Color glassFill;

  /// Light catch along the edge of a glass surface — the bright rim on the
  /// bottom nav's stadium border (Phase 7 frosted-glass polish) and the
  /// Shopping composer's border.
  final Color glassHighlight;

  /// Placeholders, eyebrow labels, disabled/tertiary metadata. Mirrors
  /// `ColorScheme.onSurfaceVariant` (secondary text) one step quieter.
  final Color textTertiary;

  /// Icon/label colour for an unselected bottom-nav destination.
  final Color navUnselected;

  /// Soft pastel-green pill painted behind the selected bottom-nav
  /// destination's icon+label (`docs/new_design`) — deliberately its own
  /// token, not a feature accent or `colorScheme.primary`, since it must
  /// read as a calm highlight, not a saturated block.
  final Color navSelectedPill;

  static const light = AppTokens(
    tasks: FeatureAccent(icon: Color(0xFF2E6B4E), container: Color(0xFFD8EDE3)),
    shopping: FeatureAccent(
      icon: Color(0xFF7A6024),
      container: Color(0xFFECE7D2),
    ),
    expenses: FeatureAccent(
      icon: Color(0xFF3C5880),
      container: Color(0xFFD6DFF0),
    ),
    members: FeatureAccent(
      icon: Color(0xFF684E7A),
      container: Color(0xFFE2D8EE),
    ),
    statistics: FeatureAccent(
      icon: Color(0xFF1F6B68),
      container: Color(0xFFD2E9E8),
    ),
    // Lightened/whitened for the floating pill shell (was 0xBDF2F0EB) — the
    // reference's nav reads as a brighter, whiter glass than the page
    // content behind it.
    glassFill: Color(0xD9FBFAF6),
    glassHighlight: Color(0x44FFFFFF),
    textTertiary: _kTertiaryText,
    navUnselected: _kNavUnselected,
    navSelectedPill: Color(0xFFDCEFDD),
  );

  @override
  AppTokens copyWith({
    FeatureAccent? tasks,
    FeatureAccent? shopping,
    FeatureAccent? expenses,
    FeatureAccent? members,
    FeatureAccent? statistics,
    Color? glassFill,
    Color? glassHighlight,
    Color? textTertiary,
    Color? navUnselected,
    Color? navSelectedPill,
  }) {
    return AppTokens(
      tasks: tasks ?? this.tasks,
      shopping: shopping ?? this.shopping,
      expenses: expenses ?? this.expenses,
      members: members ?? this.members,
      statistics: statistics ?? this.statistics,
      glassFill: glassFill ?? this.glassFill,
      glassHighlight: glassHighlight ?? this.glassHighlight,
      textTertiary: textTertiary ?? this.textTertiary,
      navUnselected: navUnselected ?? this.navUnselected,
      navSelectedPill: navSelectedPill ?? this.navSelectedPill,
    );
  }

  @override
  AppTokens lerp(covariant AppTokens? other, double t) {
    if (other == null) return this;
    return AppTokens(
      tasks: FeatureAccent.lerp(tasks, other.tasks, t),
      shopping: FeatureAccent.lerp(shopping, other.shopping, t),
      expenses: FeatureAccent.lerp(expenses, other.expenses, t),
      members: FeatureAccent.lerp(members, other.members, t),
      statistics: FeatureAccent.lerp(statistics, other.statistics, t),
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassHighlight: Color.lerp(glassHighlight, other.glassHighlight, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      navUnselected: Color.lerp(navUnselected, other.navUnselected, t)!,
      navSelectedPill: Color.lerp(navSelectedPill, other.navSelectedPill, t)!,
    );
  }
}

extension AppTokensX on BuildContext {
  /// Design tokens that ColorScheme does not cover.
  ///
  /// Falls back to [AppTokens.light] if the ambient theme never registered
  /// the extension (e.g. a widget test built with a bare `MaterialApp` and
  /// no `theme: appTheme`) — a rendering default, not a real failure worth
  /// crashing the screen over.
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokens>() ?? AppTokens.light;
}

extension TabularNumerals on TextStyle {
  /// Fixed-width numerals so figures line up in columns.
  /// Use for money, counts, public IDs, and invite codes.
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Shared, rarely-reused type roles that don't warrant their own
/// `TextTheme` slot but do warrant not being re-implemented per screen.
extension AppTextRoles on TextTheme {
  /// Uppercase-style section/group label: "Recent activity", "Completed · N".
  /// Colour is contextual — compose with `.copyWith(color: ...)`, typically
  /// `context.tokens.textTertiary` or `colorScheme.onSurfaceVariant`.
  TextStyle? get eyebrow =>
      labelSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5);

  /// Dominant numeric readout: dashboard tile counts, the Statistics hero
  /// metric, an expense amount. Always tabular — money and counts must align.
  TextStyle? get heroNumber => headlineMedium?.copyWith(
    fontWeight: FontWeight.w800,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Base decoration for a field that must never show the app's standard
/// outline, in any state — e.g. Shopping's quick-add composer, which sits on
/// its own translucent surface rather than the page background.
///
/// `InputDecorationTheme` below defines real borders for every state
/// (enabled/focused/error/disabled), which — by Flutter's own merge rules —
/// take priority over a lone widget-level `border: InputBorder.none`. Start
/// from this constant and `copyWith(...)` the parts you need (hint text,
/// padding, or a restrained focus indicator) instead of re-listing all six
/// border properties by hand.
const kBorderlessInputDecoration = InputDecoration(
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
);

// ---------------------------------------------------------------------------

const _kOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  // Android: dark glyphs on the light warm ground.
  statusBarIconBrightness: Brightness.dark,
  // iOS: describes the bar's own brightness, so it is the inverse.
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

/// Applied at startup so the system bars match the app before the first
/// AppBar builds. Re-exported so `main` does not need to know the colours.
const appSystemUiOverlayStyle = _kOverlayStyle;

final appTheme = ThemeData(
  useMaterial3: true,
  // The one place the Nunito family is set — every text role below inherits
  // it through the ambient `DefaultTextStyle`, the same way weight/spacing
  // overrides already cascade, so no per-role `fontFamily:` repetition.
  fontFamily: 'Nunito',
  colorScheme: _kColorScheme,
  extensions: const [AppTokens.light],
  // Transparent so the single shell-root `AppBackground` (see
  // `app_router.dart`) shows through every in-shell screen. The few
  // screens that render outside the shell (Task/Expense/Settlement forms,
  // Startup) explicitly opt back into `appFlatBackgroundFallback` above —
  // see the comment on that constant.
  scaffoldBackgroundColor: Colors.transparent,
  appBarTheme: const AppBarTheme(
    centerTitle: false,
    elevation: 0,
    // Was 1: a scrolled-under tint would read as a visible seam against a
    // transparent bar over the new gradient background.
    scrolledUnderElevation: 0,
    backgroundColor: Colors.transparent,
    foregroundColor: _kOnSurface,
    surfaceTintColor: Colors.transparent,
    systemOverlayStyle: _kOverlayStyle,
    // Bigger/bolder than the M3 default `titleLarge`, matching the
    // reference's large rounded screen titles.
    titleTextStyle: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      color: _kOnSurface,
    ),
    iconTheme: IconThemeData(color: _kOnSurface),
    actionsIconTheme: IconThemeData(color: _kOnSurface),
    // Phase 1 geometry pass — one shared set of constants (see
    // `AppBarMetrics`) instead of per-screen magic numbers. `leadingWidth`/
    // `titleSpacing`/`actionsPadding` size and space the new
    // `AppCircleIconButton`s; screens with no leading/actions are unaffected
    // since those slots simply aren't built.
    toolbarHeight: AppBarMetrics.toolbarHeight,
    leadingWidth: AppBarMetrics.leadingWidth,
    titleSpacing: AppBarMetrics.titleSpacing,
    actionsPadding: AppBarMetrics.actionsPadding,
  ),
  // M3's auto-derived FAB defaults to `primaryContainer`, which reads as a
  // brighter, minty tone than the rest of the interface — the same solid
  // green as FilledButton keeps the primary-create-action visually
  // consistent instead of "louder" than everything else on screen.
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: _kPrimary,
    foregroundColor: _kOnPrimary,
    elevation: 1,
    focusElevation: 1,
    hoverElevation: 2,
    highlightElevation: 2,
  ),
  // Contract: CardTheme owns both `shape` (radius) and its `side` (the
  // hairline). A widget-level `Card(shape: ...)` replaces the whole
  // OutlinedBorder — including the side — so override `color`/`margin` at
  // the call site freely, but if a card ever needs a different shape,
  // restate the side too rather than dropping the hairline silently.
  // Colour intentionally stays the tonal surface, not the new white token —
  // promoting existing cards (Homes, Expenses, Statistics) to white is a
  // composition decision for their own redesign phases, not a theme change.
  cardTheme: CardThemeData(
    elevation: 0,
    color: _kTonalSurface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      side: const BorderSide(color: _kDivider),
    ),
    margin: EdgeInsets.zero,
  ),
  dividerTheme: const DividerThemeData(
    space: 1,
    thickness: 1,
    color: _kDivider,
  ),
  listTileTheme: const ListTileThemeData(
    contentPadding: EdgeInsets.symmetric(horizontal: 16),
  ),
  // The highest-risk theme in the app: every border-state slot is defined
  // explicitly so no state can silently fall back to a different shape or
  // stroke. All six use the same OutlineInputBorder radius — only the side's
  // colour/width changes between states, which is the point: shape never
  // drifts, only emphasis does.
  //
  // A feature that must not show this outline at all (Shopping's composer)
  // starts from `kBorderlessInputDecoration` above instead of overriding
  // these six properties itself.
  inputDecorationTheme: InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: const BorderSide(color: _kDivider),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: const BorderSide(color: _kDivider),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: const BorderSide(color: _kPrimary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: _kColorScheme.error),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: _kColorScheme.error, width: 1.5),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: _kDivider.withValues(alpha: 0.5)),
    ),
    hintStyle: const TextStyle(color: _kTertiaryText),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
  ),
  dialogTheme: DialogThemeData(
    // A real (if subtle) step up from the warm ground, rather than the
    // identical colour dialogs and the scaffold shared before — the modal
    // scrim plus this lift is what now reads as "clearly a transient
    // surface" without leaning on elevation/shadow.
    backgroundColor: _kSurfaceWhite,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
    ),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: _kSurfaceWhite,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(64, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      // Explicit rather than relying on the (now-pinned) ColorScheme.outline
      // falling through — states this button's border is the same divider
      // token as every hairline and input border in the app, not a
      // coincidentally-matching value.
      side: const BorderSide(color: _kDivider),
      minimumSize: const Size(64, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 44),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  ),
  checkboxTheme: CheckboxThemeData(
    // Shape is deliberately NOT pinned here: Today/Tasks use the default
    // square box, Shopping uses `shape: CircleBorder()` for its own reasons,
    // and the app has not unified those yet (that is the future
    // AppCompletionCheckbox's job). This theme only makes colour predictable
    // across whichever shape a screen chooses.
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return _kOnSurface.withValues(alpha: 0.12);
      }
      if (states.contains(WidgetState.selected)) {
        return _kPrimary;
      }
      return Colors.transparent;
    }),
    checkColor: const WidgetStatePropertyAll(_kOnPrimary),
    side: WidgetStateBorderSide.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return BorderSide(color: _kDivider.withValues(alpha: 0.6));
      }
      if (states.contains(WidgetState.selected)) {
        return const BorderSide(color: _kPrimary, width: 2);
      }
      return const BorderSide(color: _kDivider, width: 1.5);
    }),
  ),
  // The M3 default reads unselected thumb/track/outline from
  // `ColorScheme.outline`, which this app pins to the pale divider colour —
  // on the physical device the Profile "off" switches were nearly invisible
  // against the warm ground as a result. This theme gives the off state its
  // own, more visible (but still quiet) colours instead of raising the
  // shared divider/outline token app-wide just to fix one control.
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return _kOnSurface.withValues(alpha: 0.12);
      }
      if (states.contains(WidgetState.selected)) {
        return _kOnPrimary;
      }
      return _kSecondaryText;
    }),
    trackColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return _kTonalSurface;
      }
      if (states.contains(WidgetState.selected)) {
        return _kPrimary;
      }
      return _kSurfaceContainerHigh;
    }),
    trackOutlineColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.transparent;
      }
      if (states.contains(WidgetState.disabled)) {
        return _kDivider.withValues(alpha: 0.6);
      }
      return _kSecondaryText;
    }),
  ),
  segmentedButtonTheme: SegmentedButtonThemeData(
    style: SegmentedButton.styleFrom(
      backgroundColor: _kTonalSurface,
      foregroundColor: _kSecondaryText,
      selectedBackgroundColor: _kPrimary,
      selectedForegroundColor: _kOnPrimary,
      side: const BorderSide(color: _kDivider),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      // 44dp tall: a practical, accessible tap target without the oversized
      // pill look the v1 board used.
      minimumSize: const Size(64, 44),
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: _kTonalSurface,
    side: BorderSide.none,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
  ),
  snackBarTheme: const SnackBarThemeData(
    backgroundColor: _kOnSurface,
    contentTextStyle: TextStyle(color: _kOnPrimary),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(
    color: _kPrimary,
    linearTrackColor: _kTonalSurface,
    circularTrackColor: Colors.transparent,
  ),
  // Type roles:
  //   headlineMedium — hero numeric readouts (see AppTextRoles.heroNumber)
  //   headlineSmall — screen hero (profile name)
  //   titleLarge    — AppBar / prominent titles
  //   titleMedium   — card and row titles
  //   titleSmall    — section titles
  //   bodyLarge     — list row primary text
  //   bodyMedium    — body copy
  //   bodySmall     — metadata (left at defaults; vertical rhythm is tuned
  //                   per-row by ListTile today)
  //   labelSmall    — section headers (see AppTextRoles.eyebrow)
  // Numeric emphasis is applied at the call site via `TextStyle.tabular`.
  textTheme: const TextTheme(
    headlineMedium: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4),
    headlineSmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.4),
    titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3),
    titleMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    titleSmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.1),
    bodyLarge: TextStyle(height: 1.5),
    bodyMedium: TextStyle(height: 1.45),
    labelMedium: TextStyle(letterSpacing: 0.08, fontWeight: FontWeight.w500),
    labelSmall: TextStyle(letterSpacing: 0.06, fontWeight: FontWeight.w500),
  ),
);
