import 'package:flutter_test/flutter_test.dart';
import 'package:household_os/core/services/widget_action_payload.dart';

void main() {
  group('WidgetActionPayload.parse', () {
    test('accepts a valid anytime complete payload', () {
      final payload = WidgetActionPayload.parse({
        'id': 'task-1',
        'source': 'anytime',
        'action': 'complete',
      });
      expect(payload, isNotNull);
      expect(payload!.id, 'task-1');
      expect(payload.source, 'anytime');
      expect(payload.isComplete, isTrue);
    });

    test('accepts a valid occurrence reopen payload', () {
      final payload = WidgetActionPayload.parse({
        'id': 'occ-1',
        'source': 'occurrence',
        'action': 'reopen',
      });
      expect(payload, isNotNull);
      expect(payload!.source, 'occurrence');
      expect(payload.isComplete, isFalse);
    });

    test('rejects non-map arguments', () {
      expect(WidgetActionPayload.parse('not a map'), isNull);
      expect(WidgetActionPayload.parse(null), isNull);
      expect(WidgetActionPayload.parse(42), isNull);
    });

    test('rejects a missing id', () {
      expect(
        WidgetActionPayload.parse({'source': 'anytime', 'action': 'complete'}),
        isNull,
      );
    });

    test('rejects an empty id', () {
      expect(
        WidgetActionPayload.parse({
          'id': '',
          'source': 'anytime',
          'action': 'complete',
        }),
        isNull,
      );
    });

    test('rejects an unknown source', () {
      expect(
        WidgetActionPayload.parse({
          'id': 't',
          'source': 'bogus',
          'action': 'complete',
        }),
        isNull,
      );
    });

    test('rejects a missing source — does not default to anytime', () {
      expect(
        WidgetActionPayload.parse({'id': 't', 'action': 'complete'}),
        isNull,
      );
    });

    test('rejects an unknown action', () {
      expect(
        WidgetActionPayload.parse({
          'id': 't',
          'source': 'anytime',
          'action': 'delete',
        }),
        isNull,
      );
    });
  });
}
