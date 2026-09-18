import 'package:flutter/material.dart';

/// A lightweight circular completion control shared by Today, Tasks, and
/// Shopping.
///
/// Replaces three separate `Checkbox` usages that had drifted — Today
/// suppressed the inner checkbox semantics and used a square Material box,
/// Tasks used the same square box without suppressing it, and only Shopping
/// had already moved to a circular shape. All three now share one visual
/// language and one semantics contract.
///
/// Deliberately a plain [GestureDetector], not a `Checkbox`: a real Material
/// checkbox is form-oriented (chunky filled square, a full-size ripple) and
/// the unchecked state reads as too faint against the app's warm ground —
/// exactly the two problems this control exists to fix. No ripple, no
/// `CustomPainter`, no animation package — a single `AnimatedContainer` /
/// `AnimatedOpacity` pair covers the whole transition.
class AppCompletionCheckbox extends StatelessWidget {
  const AppCompletionCheckbox({
    super.key,
    required this.checked,
    required this.semanticLabel,
    required this.onChanged,
    this.announceState = true,
  });

  /// Current completion state. For a one-way "mark done" action whose row
  /// leaves the list once completed (Today), this is always `false` and
  /// [announceState] should be `false` too — the control is a button, not a
  /// toggle, in that case.
  final bool checked;

  /// Full accessible description composed by the caller, since only it knows
  /// the item/task name and the right verb — e.g. `Mark "Buy milk" as done`
  /// or `Mark "Buy milk" as not done`.
  final String semanticLabel;

  /// Whether to expose Flutter's `checked` semantic, so assistive tech
  /// announces checked/unchecked state. Off for one-way actions (Today),
  /// on for real toggles (Tasks, Shopping).
  final bool announceState;

  final VoidCallback onChanged;

  static const _visualDiameter = 22.0;
  static const _tapTargetSize = 48.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return Semantics(
      label: semanticLabel,
      button: !announceState,
      checked: announceState ? checked : null,
      // The inner GestureDetector/Icon carry no semantics of their own that
      // should announce separately — this node is the whole story.
      excludeSemantics: true,
      // `container: true` forces this to remain its own semantics boundary
      // — the same protection Material's `Checkbox` applies internally —
      // so a `ListTile(onTap: ...)` row can't merge it into a single
      // "row is tappable" node and swallow this label into a combined one.
      container: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged,
        child: SizedBox(
          width: _tapTargetSize,
          height: _tapTargetSize,
          child: Center(
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              width: _visualDiameter,
              height: _visualDiameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checked ? colorScheme.primary : Colors.transparent,
                border: Border.all(
                  // Unchecked ring uses the secondary-text tone, not the
                  // (much fainter) pinned divider/outline colour — that
                  // fainter value is exactly what read as "too weak" against
                  // the warm ground.
                  color: checked
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  width: checked ? 0 : 1.6,
                ),
              ),
              child: AnimatedOpacity(
                duration: duration,
                opacity: checked ? 1 : 0,
                child: Icon(
                  Icons.check,
                  size: 15,
                  color: colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
