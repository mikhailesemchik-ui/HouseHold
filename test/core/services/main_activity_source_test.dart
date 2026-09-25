import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Cold start from the widget carries household_os://today as intent data,
  // which Flutter forwards as the initial route and GoRouter cannot parse.
  test(
    'MainActivity pins the initial route so intent data never reaches it',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/household/household_os/MainActivity.kt',
      ).readAsStringSync();
      expect(source, contains('override fun getInitialRoute(): String? = "/"'));
    },
  );
}
