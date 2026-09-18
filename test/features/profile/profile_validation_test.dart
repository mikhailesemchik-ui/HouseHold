import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/features/profile/domain/profile_validation.dart';

void main() {
  group('validateDisplayName', () {
    test('returns null for a valid name', () {
      expect(validateDisplayName('Alice'), isNull);
    });

    test('returns null for a name with spaces', () {
      expect(validateDisplayName('Alice Wonderland'), isNull);
    });

    test('returns error for empty string', () {
      expect(validateDisplayName(''), isNotNull);
    });

    test('returns error for whitespace-only string', () {
      expect(validateDisplayName('   '), isNotNull);
    });

    test('returns null for name exactly at max length', () {
      final name = 'a' * displayNameMaxLength;
      expect(validateDisplayName(name), isNull);
    });

    test('returns error for name exceeding max length', () {
      final name = 'a' * (displayNameMaxLength + 1);
      expect(validateDisplayName(name), isNotNull);
    });

    test('trims whitespace before checking length', () {
      // 50 valid chars padded by spaces: should be valid (trim removes spaces)
      final name = '  ${'a' * displayNameMaxLength}  ';
      expect(validateDisplayName(name), isNull);
    });
  });
}
