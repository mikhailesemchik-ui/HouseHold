import 'package:flutter/material.dart';
import 'package:household_os/app/theme/app_bar_metrics.dart';
import 'package:household_os/core/theme/app_spacing.dart';

/// The screen's title/back/action row — visually identical to the app's
/// (removed) per-screen `AppBar`, built to the same shared [AppBarMetrics]
/// geometry, but as a plain widget meant to sit as the first item inside
/// the screen's own scrollable content.
///
/// This is the Non-Sticky Headers change: the header is no longer a
/// `Scaffold.appBar` (which stays pinned while the body scrolls beneath
/// it) — it is ordinary scrollable content, so it scrolls away with the
/// rest of the page and returns naturally when scrolling back to the top.
/// Only where the header sits is different; its design is unchanged.
class AppScreenHeader extends StatelessWidget {
  const AppScreenHeader({
    super.key,
    this.leading,
    required this.title,
    this.actions = const [],
    this.bottom,
    this.compactTitle = false,
    this.centerTitle = false,
  });

  /// Typically `const Center(child: AppBackButton())`, or null for a
  /// top-level tab screen with no back action (matching the previous
  /// `AppBar`'s automatic no-leading behaviour on those screens).
  final Widget? leading;

  /// The screen title. A plain [String] (not a [Widget]) because every
  /// current call site only ever passed a `Text` — this keeps the header's
  /// text style, alignment, and overflow handling identical everywhere.
  final String title;

  /// Trailing circular action(s), e.g. an overflow/menu button.
  final List<Widget> actions;

  /// Optional content directly under the title row, at the same width —
  /// e.g. Today's date subtitle.
  final Widget? bottom;

  /// When `true`, the title shrinks to fit its available width instead of
  /// ellipsizing — for a header whose title is long relative to its
  /// leading/trailing chrome (e.g. Record Settlement's "Record settlement"
  /// next to a trailing "Record" action). Every other screen leaves this
  /// `false` and is unaffected.
  final bool compactTitle;

  /// When `true`, the title is centered on the header's full width, not in
  /// the space left between the leading and trailing controls. The side
  /// padding is the leading slot on both sides (the action buttons are
  /// narrower), so a long title ellipsizes before touching either control.
  final bool centerTitle;

  @override
  Widget build(BuildContext context) {
    final appBarTheme = Theme.of(context).appBarTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The screen's own scrollable now owns the full viewport, including
        // the status-bar band (see the `SafeArea(top: false, ...)` change at
        // each call site) — so scrolled content can visually pass under the
        // top status-bar haze instead of that band being permanently empty.
        // This spacer keeps the header itself sitting exactly where it did
        // when a `SafeArea(top: true)` used to reserve the same space.
        SizedBox(height: MediaQuery.paddingOf(context).top),
        SizedBox(
          height: AppBarMetrics.toolbarHeight,
          child: centerTitle
              ? _centeredRow(appBarTheme)
              : Row(
                  children: [
                    SizedBox(
                      width: leading == null
                          ? AppSpacing.base
                          : AppBarMetrics.leadingWidth,
                      child: leading,
                    ),
                    SizedBox(
                      width: leading == null ? 0 : AppBarMetrics.titleSpacing,
                    ),
                    Expanded(
                      child: compactTitle
                          ? FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                title,
                                style: appBarTheme.titleTextStyle,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            )
                          : Text(
                              title,
                              style: appBarTheme.titleTextStyle,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    if (actions.isNotEmpty)
                      Padding(
                        padding: AppBarMetrics.actionsPadding,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: actions,
                        ),
                      ),
                  ],
                ),
        ),
        ?bottom,
      ],
    );
  }

  Widget _centeredRow(AppBarThemeData appBarTheme) {
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal:
                  AppBarMetrics.leadingWidth + AppBarMetrics.titleSpacing,
            ),
            child: Center(
              child: Text(
                title,
                style: appBarTheme.titleTextStyle,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        Row(
          children: [
            SizedBox(width: AppBarMetrics.leadingWidth, child: leading),
            const Spacer(),
            if (actions.isNotEmpty)
              Padding(
                padding: AppBarMetrics.actionsPadding,
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
          ],
        ),
      ],
    );
  }
}
