abstract final class Money {
  static const _symbols = {'EUR': '€', 'USD': '\$', 'GBP': '£'};

  /// Formats integer cents as a currency string.
  /// Example: format(8240, 'EUR') -> '€82.40'
  static String format(int cents, String currency) {
    final symbol = _symbols[currency] ?? currency;
    final whole = cents ~/ 100;
    final fraction = (cents % 100).toString().padLeft(2, '0');
    return '$symbol$whole.$fraction';
  }

  /// Parses a decimal string into integer cents.
  /// Accepts: "82", "82.4", "82.40".
  /// Returns null for empty, zero, negative, or malformed input.
  /// Rejects more than 2 decimal places to avoid silent rounding.
  static int? parseAmountCents(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final parts = trimmed.split('.');
    if (parts.length > 2) return null;

    final wholePart = parts[0];
    final fracPart = parts.length == 2 ? parts[1] : '';

    if (wholePart.isEmpty) return null;
    if (fracPart.length > 2) return null;

    final wholeInt = int.tryParse(wholePart);
    if (wholeInt == null || wholeInt < 0) return null;

    final fracStr = fracPart.padRight(2, '0');
    final fracInt = int.tryParse(fracStr);
    if (fracInt == null) return null;

    final cents = wholeInt * 100 + fracInt;
    if (cents <= 0) return null;

    return cents;
  }

  /// Calculates equal share amounts for [participantCount] participants.
  /// Returns a list where the first elements absorb the remainder.
  /// Example: equalSplitShares(1000, 3) -> [334, 333, 333]
  static List<int> equalSplitShares(int amountCents, int participantCount) {
    assert(participantCount > 0, 'participantCount must be positive');
    final base = amountCents ~/ participantCount;
    final remainder = amountCents % participantCount;
    return List.generate(
      participantCount,
      (i) => i < remainder ? base + 1 : base,
    );
  }
}
