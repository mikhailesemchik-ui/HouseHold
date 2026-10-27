import 'package:flutter/foundation.dart';
import 'package:household_os/features/expenses/domain/money.dart';

/// Parses the text of an amount field into integer cents.
///
/// The iOS decimal keypad types a comma in many regions, and users cannot
/// type a period there. The domain parser stays strict (period only), so the
/// comma is mapped to a period here, at the input boundary, and only on iOS —
/// Android input is parsed exactly as typed. Every comma is replaced, so
/// "12,5,0" and "1,000" still fail the strict parse rather than being guessed.
int? parseAmountInput(String input, TargetPlatform platform) {
  final text = platform == TargetPlatform.iOS
      ? input.replaceAll(',', '.')
      : input;
  return Money.parseAmountCents(text);
}

/// The validation message for an amount field, or null when the text is a
/// valid amount. Distinguishes malformed input from an amount above the
/// per-operation limit so the user knows what to fix.
String? amountInputError(String input, TargetPlatform platform) {
  if (parseAmountInput(input, platform) != null) return null;
  final text = platform == TargetPlatform.iOS
      ? input.replaceAll(',', '.')
      : input;
  if (Money.exceedsMaximum(text)) {
    return 'The amount cannot exceed €1,000,000.00';
  }
  return 'Enter a valid amount (e.g. 12.50)';
}
