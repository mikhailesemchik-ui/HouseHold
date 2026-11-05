import 'dart:math' as math;

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
  /// ellipsizing, whether or not it is centered — for a header whose title is
  /// long relative to its leading/trailing chrome (e.g. Record Settlement's
  /// "Record settlement" next to a trailing "Record" action, or a centered
  /// title at large text scales). Other screens leave this `false`.
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
                      child: _insetLeading(),
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

  // The leading slot is centred in a 72dp slot, which parks the 56dp circle
  // 8dp from the screen edge. Insetting the slot's left by the 16dp content
  // margin puts the painted circle on the same edge as the content cards
  // while keeping the slot width, and so the title position, unchanged.
  Widget? _insetLeading() => leading == null
      ? null
      : Padding(
          padding: const EdgeInsets.only(left: AppSpacing.base),
          child: leading,
        );

  Widget _centeredRow(AppBarThemeData appBarTheme) {
    return CustomMultiChildLayout(
      delegate: _CenteredHeaderLayout(),
      children: [
        LayoutId(
          id: _HeaderSlot.leading,
          child: _insetLeading() ?? const SizedBox.shrink(),
        ),
        if (actions.isNotEmpty)
          LayoutId(
            id: _HeaderSlot.trailing,
            child: Padding(
              padding: AppBarMetrics.actionsPadding,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ),
        LayoutId(
          id: _HeaderSlot.title,
          child: _CenteredTitle(
            title: title,
            style: appBarTheme.titleTextStyle,
            compact: compactTitle,
          ),
        ),
      ],
    );
  }
}

enum _HeaderSlot { leading, trailing, title }

/// Centres the title on the full header width, reserving the same room on
/// both sides: the larger of the leading slot and the trailing actions'
/// measured width (which grows with text scale).
///
/// When a wide trailing action would leave the symmetric title area much
/// narrower than the space actually free between the two controls, the title
/// is centred in that free space instead, so large text never forces the
/// title to shrink to an unreadable size just to stay on the exact centre.
class _CenteredHeaderLayout extends MultiChildLayoutDelegate {
  _CenteredHeaderLayout();

  /// Minimum share of the free space the symmetric area must keep.
  static const _minSymmetricShare = 0.8;

  @override
  void performLayout(Size size) {
    layoutChild(
      _HeaderSlot.leading,
      BoxConstraints.tightFor(
        width: AppBarMetrics.leadingWidth,
        height: size.height,
      ),
    );
    positionChild(_HeaderSlot.leading, Offset.zero);

    final leadingReserve =
        AppBarMetrics.leadingWidth + AppBarMetrics.titleSpacing;
    var trailingReserve = 0.0;
    if (hasChild(_HeaderSlot.trailing)) {
      final trailing = layoutChild(
        _HeaderSlot.trailing,
        BoxConstraints(
          maxWidth: size.width - AppBarMetrics.leadingWidth,
          maxHeight: size.height,
        ),
      );
      positionChild(
        _HeaderSlot.trailing,
        Offset(
          size.width - trailing.width,
          (size.height - trailing.height) / 2,
        ),
      );
      trailingReserve = trailing.width + AppBarMetrics.titleSpacing;
    }

    final side = math.max(leadingReserve, trailingReserve);
    final symmetricWidth = math.max(0.0, size.width - 2 * side);
    final freeWidth = math.max(
      0.0,
      size.width - leadingReserve - trailingReserve,
    );
    // Only a trailing action wider than the leading slot can eat into the
    // symmetric area; otherwise the title is always on the exact centre.
    final centred =
        trailingReserve <= leadingReserve ||
        symmetricWidth >= _minSymmetricShare * freeWidth;
    final left = centred ? side : leadingReserve;
    final width = centred ? symmetricWidth : freeWidth;

    final title = layoutChild(
      _HeaderSlot.title,
      BoxConstraints(maxWidth: width, maxHeight: size.height),
    );
    positionChild(
      _HeaderSlot.title,
      Offset(
        left + (width - title.width) / 2,
        (size.height - title.height) / 2,
      ),
    );
  }

  @override
  bool shouldRelayout(covariant _CenteredHeaderLayout oldDelegate) => false;
}

/// The header title for [_CenteredHeaderLayout]. A compact title that would
/// have to shrink below [_minSingleLineScale] on one line is broken at a
/// space into two lines instead, which keeps it larger and readable.
class _CenteredTitle extends StatelessWidget {
  const _CenteredTitle({
    required this.title,
    required this.style,
    required this.compact,
  });

  final String title;
  final TextStyle? style;
  final bool compact;

  static const _minSingleLineScale = 0.85;

  @override
  Widget build(BuildContext context) {
    if (!compact) {
      return Text(
        title,
        style: style,
        maxLines: 1,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneLineWidth = _singleLineWidth(context);
        final twoLines = _twoLineTitle();
        final useTwoLines =
            twoLines != null &&
            constraints.maxWidth / oneLineWidth < _minSingleLineScale;
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            useTwoLines ? twoLines : title,
            // Tighter leading so two lines fit the toolbar height.
            style: useTwoLines ? style?.copyWith(height: 1.1) : style,
            maxLines: useTwoLines ? 2 : 1,
            softWrap: false,
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }

  double _singleLineWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// [title] broken at the space closest to its middle, or null without one.
  String? _twoLineTitle() {
    final middle = title.length / 2;
    int? best;
    for (var i = 0; i < title.length; i++) {
      if (title[i] != ' ') continue;
      if (best == null || (i - middle).abs() < (best - middle).abs()) best = i;
    }
    if (best == null) return null;
    return '${title.substring(0, best)}\n${title.substring(best + 1)}';
  }
}
