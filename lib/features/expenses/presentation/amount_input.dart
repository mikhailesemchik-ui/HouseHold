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
