import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/widgets/app_activity_row.dart';
import 'package:household_os/features/homes/domain/household_event.dart';

void main() {
  HouseholdEvent makeEvent({
    String eventType = 'task_completed',
    String? titleSnapshot = 'Clean kitchen',
    DateTime? occurredAt,
  }) {
    return HouseholdEvent(
      id: 'evt-1',
      householdId: 'hh-1',
      actorDisplayName: 'Anna',
      eventType: eventType,
      entityType: 'task',
      titleSnapshot: titleSnapshot,
      occurredAt:
          occurredAt ?? DateTime.now().subtract(const Duration(hours: 2)),
    );
  }

  Widget wrap(Widget child, {TextScaler? textScaler}) {
    return MediaQuery(
      data: MediaQueryData(textScaler: textScaler ?? TextScaler.noScaling),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('shows an icon so meaning is not colour-only', (tester) async {
    await tester.pumpWidget(wrap(AppActivityRow(event: makeEvent())));
    expect(find.byIcon(Icons.task_alt), findsOneWidget);
  });

  testWidgets('long event text does not overflow at 2.0x text scale', (
    tester,
  ) async {
    final event = makeEvent(
      titleSnapshot:
          'Deep clean the entire upstairs bathroom including the grout '
          'and the extractor fan above the shower',
    );
    await tester.pumpWidget(
      wrap(
        SizedBox(width: 320, child: AppActivityRow(event: event)),
        textScaler: const TextScaler.linear(2.0),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('semantic description reads title before timestamp', (
    tester,
  ) async {
    final event = makeEvent(
      titleSnapshot: 'Clean kitchen',
      occurredAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    await tester.pumpWidget(wrap(AppActivityRow(event: event)));

    final semantics = tester.getSemantics(find.byType(ListTile));
    final title = semantics.label.indexOf('Anna completed "Clean kitchen"');
    final time = semantics.label.indexOf('m ago');
    expect(title, greaterThanOrEqualTo(0));
    expect(time, greaterThan(title));
  });

  testWidgets('dense mode is available for the dashboard preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(AppActivityRow(event: makeEvent(), dense: true)),
    );
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.dense, isTrue);
  });
}
