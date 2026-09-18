import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_background.dart';
import 'package:household_os/features/homes/presentation/household_detail_screen.dart';
import 'package:household_os/features/homes/presentation/homes_screen.dart';
import 'package:household_os/features/profile/presentation/profile_screen.dart';
import 'package:household_os/features/expenses/presentation/expenses_screen.dart';
import 'package:household_os/features/homes/presentation/activity_screen.dart';
import 'package:household_os/features/homes/presentation/members_screen.dart';
import 'package:household_os/features/homes/presentation/statistics_screen.dart';
import 'package:household_os/features/shopping/presentation/shopping_screen.dart';
import 'package:household_os/features/startup/presentation/startup_screen.dart';
import 'package:household_os/features/tasks/presentation/tasks_screen.dart';
import 'package:household_os/features/today/presentation/today_screen.dart';

/// The three shell destinations the floating bottom nav belongs to — every
/// other route (household dashboard, its nested screens, pushed forms) is
/// "deeper" and hides it. Exact-path identity, not `.contains`/depth
/// guessing, so a route is unambiguously root or not.
const _kShellRootPaths = {'/today', '/homes', '/profile'};

/// Whether [path] is exactly one of the shell's root destinations — see
/// [_kShellRootPaths]. Exposed (not `_`-prefixed) so it's unit-testable
/// without needing a real `GoRouter`.
bool isShellRootPath(String path) => _kShellRootPaths.contains(path);

final appRouter = GoRouter(
  initialLocation: '/startup',
  routes: [
    GoRoute(
      path: '/startup',
      builder: (context, state) => const StartupScreen(),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return _ShellScaffold(
          navigationShell: navigationShell,
          showNav: isShellRootPath(state.uri.path),
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/today',
              builder: (context, state) => const TodayScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/homes',
              builder: (context, state) => const HomesScreen(),
              routes: [
                GoRoute(
                  path: ':householdId',
                  builder: (context, state) {
                    final id = state.pathParameters['householdId']!;
                    return HouseholdDetailScreen(householdId: id);
                  },
                  routes: [
                    GoRoute(
                      path: 'tasks',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return TasksScreen(householdId: id);
                      },
                    ),
                    GoRoute(
                      path: 'shopping',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return ShoppingScreen(householdId: id);
                      },
                    ),
                    GoRoute(
                      path: 'expenses',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return ExpensesScreen(householdId: id);
                      },
                    ),
                    GoRoute(
                      path: 'members',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return MembersScreen(householdId: id);
                      },
                    ),
                    GoRoute(
                      path: 'statistics',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return StatisticsScreen(householdId: id);
                      },
                    ),
                    GoRoute(
                      path: 'activity',
                      builder: (context, state) {
                        final id = state.pathParameters['householdId']!;
                        return ActivityScreen(householdId: id);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

class _ShellScaffold extends StatefulWidget {
  const _ShellScaffold({required this.navigationShell, required this.showNav});

  final StatefulNavigationShell navigationShell;

  /// Whether the current route is one of the shell's three root
  /// destinations — see [isShellRootPath]. `false` on every deeper/nested
  /// route (household dashboard, its nested screens, pushed forms), where
  /// the floating bottom nav must be hidden.
  final bool showNav;

  @override
  State<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends State<_ShellScaffold>
    with SingleTickerProviderStateMixin {
  // Tracks the *previous* build's keyboard-open state so we can detect the
  // open→closed transition below — see the comment at its one use site.
  bool _keyboardWasOpen = false;

  // Telegram-style directional entrance for top-level tab switches only —
  // see `didUpdateWidget`. Deliberately NOT a PageView/AnimatedSwitcher: the
  // shell's single `StatefulNavigationShell` instance is never swapped or
  // rebuilt with a new key, so its branch Navigators/scroll state are never
  // duplicated or torn down. This controller only drives a paint-layer
  // transform+fade over whichever branch is already showing.
  late final AnimationController _entranceController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 1,
  );
  double _entranceDirection = 0;

  @override
  void didUpdateWidget(covariant _ShellScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIndex = oldWidget.navigationShell.currentIndex;
    final newIndex = widget.navigationShell.currentIndex;
    // Only a top-level tab switch gets the directional entrance — a nested
    // navigation change *within* a branch (e.g. Homes → Tasks) rebuilds this
    // widget too but leaves `currentIndex` unchanged, so it's correctly
    // skipped here.
    if (oldIndex == newIndex) return;
    _entranceDirection = newIndex > oldIndex ? 1 : -1;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entranceController.value = 1;
    } else {
      _entranceController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ---------------------------------------------------------------------
    // This Scaffold owns keyboard resizing for every screen in the shell.
    //
    // Its default `resizeToAvoidBottomInset: true` makes Flutter strip
    // `viewInsets.bottom` to zero for everything in its body, so the screens
    // below are structurally blind to the keyboard: they must not read
    // `MediaQuery.viewInsets`, must not add keyboard offsets, and must not
    // set `resizeToAvoidBottomInset` themselves. Their own viewport is
    // already sized above the keyboard, so bottom-docked controls anchor to
    // it directly. A feature that needs to know whether *its own* field is
    // focused uses a FocusNode, not an inset (see Shopping's composer).
    //
    // This read is valid only because it happens above the Scaffold, where
    // the inset has not been consumed yet.
    // ---------------------------------------------------------------------
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    if (_keyboardWasOpen && !keyboardOpen) {
      // The system keyboard just closed. On Android, pressing the hardware
      // back button while a field is focused is handled entirely by the
      // IME — it hides the keyboard without ever clearing Flutter's own
      // focus. Left alone, a screen whose "focused" layout branch depends
      // on that focus (e.g. Shopping's composer, positioned near the
      // now-gone keyboard) never re-anchors above the nav bar this Scaffold
      // is about to restore. Unfocusing here, the one place that sees the
      // real transition before the resize boundary consumes it, closes that
      // gap for every screen in the shell at once instead of each screen
      // guessing at "is the keyboard really gone" on its own.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    }
    _keyboardWasOpen = keyboardOpen;

    return Scaffold(
      // Transparent so the single `AppBackground` layer below shows through
      // with no seam at the Scaffold's own background. `AppBackground` is
      // wired exactly once, here at the shell root — every screen nested in
      // this shell (all StatefulShellRoute branches) inherits it; it must
      // not be wrapped again per-screen.
      backgroundColor: Colors.transparent,
      // extendBody lets content scroll beneath the translucent nav bar so the
      // Liquid Glass blur has something to composite over. It also makes
      // Flutter publish the nav bar's measured height to descendants as
      // `MediaQuery.padding.bottom` — the single source of bottom clearance
      // for every screen in the shell (see `AppShellMetrics`).
      extendBody: true,
      // AppBackground itself is never wrapped by the entrance transform
      // below — only its child (the actual branch content) shifts/fades,
      // so the gradient stays exactly fixed, per the frozen background
      // contract.
      body: AppBackground(
        child: AnimatedBuilder(
          animation: _entranceController,
          builder: (context, child) {
            final t = Curves.easeOutQuint.transform(_entranceController.value);
            return Transform.translate(
              offset: Offset(_entranceDirection * 16 * (1 - t), 0),
              child: Opacity(opacity: 0.92 + 0.08 * t, child: child),
            );
          },
          child: widget.navigationShell,
        ),
      ),
      // Hidden for two independent reasons: a deeper/nested route
      // (`!widget.showNav`) or the keyboard covering it. Setting
      // `bottomNavigationBar` to null in either case is the same mechanism
      // already relied on for the keyboard case — Scaffold's own layout
      // (see `_BodyBuilder`) then falls the body's `MediaQuery.padding.bottom`
      // back to the device's own safe-area inset, never to a phantom gap.
      bottomNavigationBar: (keyboardOpen || !widget.showNav)
          ? null
          : _FloatingNavShell(
              selectedIndex: widget.navigationShell.currentIndex,
              // Re-tapping the current branch returns to its root route.
              onDestinationSelected: (index) => widget.navigationShell.goBranch(
                index,
                initialLocation: index == widget.navigationShell.currentIndex,
              ),
            ),
    );
  }
}

/// Reserves the device's own bottom safe area — exactly what stock
/// `NavigationBar` did internally via its own `SafeArea` (verified against
/// the Flutter SDK source, `navigation_bar.dart`) — plus a small floating
/// gap, then lays the glass pill inset from both sides. This widget's total
/// rendered height is what `Scaffold(extendBody: true)` publishes as
/// `context.shellBottomInset` to every screen in the shell; nothing else
/// needs to know the margins/gap changed.
class _FloatingNavShell extends StatelessWidget {
  const _FloatingNavShell({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.base,
          0,
          AppSpacing.base,
          AppSpacing.md,
        ),
        child: _GlassNavBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
        ),
      ),
    );
  }
}

class _NavDestination {
  const _NavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _kNavDestinations = [
  _NavDestination(
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    label: 'Today',
  ),
  _NavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Homes',
  ),
  _NavDestination(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Profile',
  ),
];

// Telegram-derived frosted-glass prototype — NAV ONLY (Shopping composer
// stays on the frozen `tokens.glassFill`/`tokens.glassHighlight` values).
// Material reference only, not copied code/shaders — see task notes.
// Lower fill opacity + stronger blur + a quiet dark edge, replacing the
// bright/white rim so separation over a white card comes from the edge
// itself, not from the fill staying near-opaque.
const double _kNavGlassBlurSigma = 28.0;
const Color _kNavGlassFill = Color(0xC2FBFAF6);
const double _kNavGlassHighlightPeak = 0.12;
const Color _kNavGlassRimColor = Color(0x18000000);
const double _kNavGlassRimWidth = 0.5;
const List<BoxShadow> _kNavGlassShadows = [
  BoxShadow(color: Color(0x20000000), offset: Offset(0, 1), blurRadius: 6),
];

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    // `side` only affects painting, not the clip path, so this one shape is
    // safe to reuse for both the shadow/rim decoration and the clip below.
    const shape = StadiumBorder(
      side: BorderSide(color: _kNavGlassRimColor, width: _kNavGlassRimWidth),
    );

    // The only other BackdropFilter in the app besides the Shopping
    // composer. Liquid Glass belongs to the functional layer (navigation)
    // — never to content rows or cards.
    return DecoratedBox(
      decoration: const ShapeDecoration(
        shape: shape,
        shadows: _kNavGlassShadows,
      ),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _kNavGlassBlurSigma,
            sigmaY: _kNavGlassBlurSigma,
          ),
          child: Stack(
            children: [
              // Base translucent warm-white fill.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: _kNavGlassFill),
                ),
              ),
              // Subtle inner highlight — light catching the top/left of the
              // glass surface. Restrained to a tiny light-catch now that the
              // fill itself carries much less opacity — must not read as a
              // white wash.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0.0, 0.45],
                      colors: [
                        Colors.white.withValues(alpha: _kNavGlassHighlightPeak),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  // Shell-internal: screens read the resulting measured
                  // height from `MediaQuery.padding.bottom`, never from
                  // this constant.
                  height: kNavBarContentHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, destination) in _kNavDestinations.indexed)
                        Expanded(
                          child: _NavDestinationTile(
                            destination: destination,
                            selected: i == selectedIndex,
                            onTap: () => onDestinationSelected(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavDestinationTile extends StatelessWidget {
  const _NavDestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : tokens.navUnselected;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // Selected-state duration shared by the pill bloom and the icon/label
    // color crossfade, so both read as one coherent transition. The icon
    // shape morph below is intentionally a bit faster (its own separate
    // duration) — matching Telegram's own icon/background split timing.
    final selectedStateDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 300);
    final iconMorphDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200);

    return Semantics(
      label: destination.label,
      selected: selected,
      button: true,
      container: true,
      inMutuallyExclusiveGroup: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        // No visible ink/hover/focus state layer — the only feedback for
        // selection is the pale-green pill above, painted from `selected`.
        // Without this, InkWell's default rectangular splash/highlight
        // flashes gray behind the tapped tile during the transition.
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The selected pill "blooms" from the destination's own
              // center — scale 0.6→1.0 + opacity 0→1 — instead of the
              // previous flat color crossfade. Sized by the foreground
              // content below via `Positioned.fill` (Stack sizes itself to
              // its one non-positioned child), so the badge always matches
              // the icon+label footprint exactly, unchanged from before.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: selected ? 1 : 0,
                    duration: selectedStateDuration,
                    curve: Curves.easeOutQuint,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0.6,
                      duration: selectedStateDuration,
                      curve: Curves.easeOutQuint,
                      alignment: Alignment.center,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.navSelectedPill,
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TweenAnimationBuilder<Color?>(
                  duration: selectedStateDuration,
                  curve: Curves.easeOutQuint,
                  tween: ColorTween(end: color),
                  builder: (context, animatedColor, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: iconMorphDuration,
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.9,
                              end: 1.0,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: Icon(
                          selected
                              ? destination.selectedIcon
                              : destination.icon,
                          key: ValueKey(selected),
                          color: animatedColor,
                          size: 24,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        destination.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: animatedColor,
                          letterSpacing: 0.05,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
