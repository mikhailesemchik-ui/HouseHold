import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_completion_checkbox.dart';

void main() {
  Widget wrap(Widget child, {TextScaler? textScaler}) {
    return MediaQuery(
      data: MediaQueryData(textScaler: textScaler ?? TextScaler.noScaling),
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  testWidgets('unchecked toggle exposes the caller-supplied label and state', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: false,
          semanticLabel: 'Mark "Buy milk" as done',
          onChanged: () {},
        ),
      ),
    );

    final semantics = tester.getSemantics(find.byType(AppCompletionCheckbox));
    expect(semantics.label, 'Mark "Buy milk" as done');
    expect(semantics.flagsCollection.isChecked, CheckedState.isFalse);
  });

  testWidgets('checked toggle exposes the checked state', (tester) async {
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: true,
          semanticLabel: 'Mark "Buy milk" as not done',
          onChanged: () {},
        ),
      ),
    );

    final semantics = tester.getSemantics(find.byType(AppCompletionCheckbox));
    expect(semantics.label, 'Mark "Buy milk" as not done');
    expect(semantics.flagsCollection.isChecked, CheckedState.isTrue);
  });

  testWidgets('one-way action exposes a button, not a checked state', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: false,
          announceState: false,
          semanticLabel: 'Mark "Water plants" as done',
          onChanged: () {},
        ),
      ),
    );

    final semantics = tester.getSemantics(find.byType(AppCompletionCheckbox));
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isChecked, CheckedState.none);
  });

  testWidgets('tap invokes the callback exactly once', (tester) async {
    var callCount = 0;
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: false,
          semanticLabel: 'Mark "Buy milk" as done',
          onChanged: () => callCount++,
        ),
      ),
    );

    await tester.tap(find.byType(AppCompletionCheckbox));
    expect(callCount, 1);
  });

  testWidgets('effective tap target is at least 48x48', (tester) async {
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: false,
          semanticLabel: 'Mark "Buy milk" as done',
          onChanged: () {},
        ),
      ),
    );

    final size = tester.getSize(find.byType(AppCompletionCheckbox));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('renders without overflow at 2.0x text scale', (tester) async {
    await tester.pumpWidget(
      wrap(
        AppCompletionCheckbox(
          checked: true,
          semanticLabel: 'Mark "Buy milk" as not done',
          onChanged: () {},
        ),
        textScaler: const TextScaler.linear(2.0),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('does not merge into an ancestor ListTile(onTap:) label', (
    tester,
  ) async {
    // Regression guard: a plain Semantics wrapper (without `container: true`)
    // gets absorbed into a tappable ListTile's combined row label, silently
    // losing this control's own distinct semantics.
    await tester.pumpWidget(
      wrap(
        ListTile(
          leading: AppCompletionCheckbox(
            checked: false,
            semanticLabel: 'Mark "Take out trash" as done',
            onChanged: () {},
          ),
          title: const Text('Take out trash'),
          onTap: () {},
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Mark "Take out trash" as done'),
      findsOneWidget,
    );
  });
}
