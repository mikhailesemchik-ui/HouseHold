import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/expenses/presentation/amount_input.dart';

void main() {
  group('parseAmountInput on iOS', () {
    const ios = TargetPlatform.iOS;

    test('accepts the comma the iOS decimal keypad types', () {
      expect(parseAmountInput('12,50', ios), 1250);
      expect(parseAmountInput('12,5', ios), 1250);
      expect(parseAmountInput('0,99', ios), 99);
    });

    test('still accepts a period and whole numbers', () {
      expect(parseAmountInput('12.50', ios), 1250);
      expect(parseAmountInput('12', ios), 1200);
    });

    test('rejects malformed values instead of guessing', () {
      expect(parseAmountInput('', ios), isNull);
      expect(parseAmountInput('abc', ios), isNull);
      expect(parseAmountInput('12,5,0', ios), isNull);
      expect(parseAmountInput('12,50.1', ios), isNull);
      expect(parseAmountInput('12,505', ios), isNull);
      expect(parseAmountInput('1,000', ios), isNull);
      expect(parseAmountInput(',50', ios), isNull);
      expect(parseAmountInput('0,00', ios), isNull);
    });
  });

  group('parseAmountInput on Android', () {
    const android = TargetPlatform.android;

    test('is exactly the strict domain parser', () {
      expect(parseAmountInput('12.50', android), 1250);
      expect(parseAmountInput('12', android), 1200);
      expect(parseAmountInput('12,50', android), isNull);
    });
  });
}
