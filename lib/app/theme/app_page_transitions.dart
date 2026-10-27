import 'package:flutter/cupertino.dart';
import 'package:household_os/core/widgets/app_background.dart';

/// iOS push transition: the native Cupertino slide and swipe-back, with each
/// pushed page given its own [AppBackground].
///
/// Screens are transparent by design so the shell-root [AppBackground] shows
/// through. That is fine while a page is static, but a Cupertino push slides
/// the new page over the old one, and two transparent pages let both contents
/// show through each other for the whole transition. Painting the same
/// background on the pushed page makes it cover the page beneath.
///
/// Branch roots (the first route of a navigator) never slide in, and
/// full-screen dialogs already paint their own flat background, so both are
/// left untouched.
class AppCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppCupertinoPageTransitionsBuilder();

  static const _cupertino = CupertinoPageTransitionsBuilder();

  // Without these the base class defaults (300 ms) would replace Cupertino's
  // own timing, which its curves are tuned for.
  @override
  Duration get transitionDuration => _cupertino.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _cupertino.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _cupertino.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final needsBackground = !route.isFirst && !route.fullscreenDialog;
    return _cupertino.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      needsBackground ? AppBackground(child: child) : child,
    );
  }
}
