import 'package:flutter/material.dart';
import 'package:household_os/app/theme/app_theme.dart';

/// Renders an already-formatted amount (e.g. the output of `Money.format`)
/// with tabular figures, so a column of amounts lines up digit-for-digit.
///
/// Presentation only — this widget does not parse, format, or calculate
/// money, and knows nothing about currency or debt semantics. Callers still
/// own formatting via the existing `Money` domain code; pass the result in.
class AppMoneyText extends StatelessWidget {
  const AppMoneyText(this.formatted, {super.key, this.style});

  /// The already-formatted amount string to display.
  final String formatted;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Text(formatted, style: (style ?? const TextStyle()).tabular);
  }
}
