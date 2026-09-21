import 'package:flutter/material.dart';
import 'package:household_os/app/routing/app_router.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:inspire_blur/inspire_blur.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Household OS',
      theme: appTheme,
      routerConfig: appRouter,
      builder: (context, child) => Stack(
        children: [
          ?child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.paddingOf(context).top + 48,
            child: const _TopStatusBarHaze(),
          ),
        ],
      ),
    );
  }
}

/// A decorative-only atmospheric glow behind the real Android status bar
/// (time/wifi/battery/notification icons) — global, not gated by nav
/// visibility, since it belongs to the physical top edge of the app rather
/// than any one screen. `IgnorePointer` + no Semantics: purely paint, no
/// layout reservation, no SafeArea change, no hit-testing. Proven insertion
/// point: `MaterialApp.router.builder` renders above the real system UI
/// (confirmed by an earlier magenta visibility diagnostic, since removed).
///
/// The progressive blur itself (strongest at the physical top, fading to
/// nothing toward the bottom of this band) comes from `inspire_blur`'s
/// `Inspire.backdropBlur` — a true variable-strength GPU shader blur, not a
/// uniform `BackdropFilter` combined with a separate alpha mask. A plain,
/// much lighter cream `DecoratedBox` gradient sits on top only to tie the
/// blurred band into the app's warm palette; the blur itself does the
/// visual separation.
class _TopStatusBarHaze extends StatelessWidget {
  const _TopStatusBarHaze();

  static const _warmCream = Color(0xFFFBFAF6);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Inspire.backdropBlur(
            config: InspireBlurConfig.topToBottom(sigma: 5.5),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.35, 0.70, 1.0],
                colors: [
                  _warmCream.withValues(alpha: 0.18),
                  _warmCream.withValues(alpha: 0.11),
                  _warmCream.withValues(alpha: 0.04),
                  _warmCream.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
