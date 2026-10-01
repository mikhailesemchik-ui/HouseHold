import 'package:flutter/foundation.dart';

/// A validated widget row action. Treat the native side's raw arguments as
/// untrusted input — [parse] returns null for anything malformed, rather
/// than guessing at missing/invalid fields.
@immutable
class WidgetActionPayload {
  const WidgetActionPayload({
    required this.id,
    required this.source,
    required this.action,
  });

  /// Occurrence id when [source] is `occurrence`, task id when `anytime`.
  final String id;
  final String source;
  final String action;

  bool get isComplete => action == 'complete';

  static WidgetActionPayload? parse(Object? rawArguments) {
    if (rawArguments is! Map) return null;
    final id = rawArguments['id'];
    final source = rawArguments['source'];
    final action = rawArguments['action'];
    if (id is! String || id.isEmpty) return null;
    if (source != 'occurrence' && source != 'anytime') return null;
    if (action != 'complete' && action != 'reopen') return null;
    return WidgetActionPayload(id: id, source: source, action: action);
  }
}
