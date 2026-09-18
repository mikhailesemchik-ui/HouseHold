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

  @override
  Widget build(BuildContext context) {
    final appBarTheme = Theme.of(context).appBarTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: AppBarMetrics.toolbarHeight,
          child: Row(
            children: [
              SizedBox(
                width: leading == null
                    ? AppSpacing.base
                    : AppBarMetrics.leadingWidth,
                child: leading,
              ),
              SizedBox(width: leading == null ? 0 : AppBarMetrics.titleSpacing),
              Expanded(
                child: Text(
                  title,
                  style: appBarTheme.titleTextStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: AppBarMetrics.actionsPadding,
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
            ],
          ),
        ),
        ?bottom,
      ],
    );
  }
}
