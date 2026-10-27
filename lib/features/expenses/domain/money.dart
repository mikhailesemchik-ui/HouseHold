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

  /// Largest amount of a single operation, in cents (1,000,000.00). Inclusive.
  /// The database enforces the same limit.
  static const int maxCents = 100000000;

  static final _digits = RegExp(r'^[0-9]+$');

  /// Parses a decimal string into integer cents.
  /// Accepts: "82", "82.4", "82.40".
  /// Returns null for empty, zero, negative, malformed or oversized input
  /// (more than [maxCents]). Rejects more than 2 decimal places to avoid
  /// silent rounding. Never overflows: the size is decided from the digit
  /// count before any multiplication happens.
  static int? parseAmountCents(String input) => _parse(input).cents;

  /// Whether [input] is a well-formed amount that is larger than [maxCents].
  static bool exceedsMaximum(String input) => _parse(input).tooLarge;

  static ({int? cents, bool tooLarge}) _parse(String input) {
    const invalid = (cents: null, tooLarge: false);
    final trimmed = input.trim();
    if (trimmed.isEmpty) return invalid;

    final parts = trimmed.split('.');
    if (parts.length > 2) return invalid;

    final wholePart = parts[0];
    final fracPart = parts.length == 2 ? parts[1] : '';

    if (!_digits.hasMatch(wholePart)) return invalid;
    if (fracPart.isNotEmpty && !_digits.hasMatch(fracPart)) return invalid;
    if (fracPart.length > 2) return invalid;

    // maxCents has 7 whole-unit digits (1,000,000), so anything longer is too
    // large no matter what follows; shorter values are safe to multiply.
    final significant = wholePart.replaceFirst(RegExp(r'^0+'), '');
    if (significant.length > 7) return (cents: null, tooLarge: true);

    final whole = significant.isEmpty ? 0 : int.parse(significant);
    final cents = whole * 100 + int.parse(fracPart.padRight(2, '0'));
    if (cents <= 0) return invalid;
    if (cents > maxCents) return (cents: null, tooLarge: true);
    return (cents: cents, tooLarge: false);
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
