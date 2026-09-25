import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // The native provider must read the same preferences home_widget writes to
  // (NW-002); a hand-typed file name silently read nothing.
  final provider = File(
    'android/app/src/main/kotlin/com/household/household_os/'
    'HouseholdOsWidgetProvider.kt',
  ).readAsStringSync();
  final snapshotWriter = File(
    'lib/core/services/widget_snapshot.dart',
  ).readAsStringSync();

  test('provider reads home_widget shared preferences via its helper', () {
    expect(provider, contains('HomeWidgetPlugin.getData(context)'));
    expect(provider, isNot(contains('getSharedPreferences(')));
  });

  test('provider only reads keys the Flutter snapshot writes', () {
    final keys = RegExp(
      r'sp\.get\w+\("(widget_\w+)"',
    ).allMatches(provider).map((m) => m.group(1)!).toSet();
    expect(keys, isNotEmpty);
    for (final key in keys) {
      final base = key.replaceAll(RegExp(r'_\d+_'), r'_${i}_');
      expect(
        snapshotWriter.contains("'$key'") || snapshotWriter.contains("'$base"),
        isTrue,
        reason: 'Flutter never writes $key',
      );
    }
  });
}
