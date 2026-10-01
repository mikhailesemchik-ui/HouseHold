import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/services/widget_action_handler.dart';
import 'package:household_os/core/services/widget_action_payload.dart';

const _channel = MethodChannel('com.household.household_os/widget_action');

/// Headless entrypoint for a widget row tap. Started directly by name
/// (`DartExecutor.executeDartEntrypoint`) from [HouseholdOsWidgetActionWorker],
/// not through home_widget's callback-handle dispatch — that path was traced
/// and confirmed to never reach Dart in this project. This boots nothing
/// beyond what one task mutation needs: no runApp, no notifications/push.
@pragma('vm:entry-point')
void widgetActionMain() {
  WidgetsFlutterBinding.ensureInitialized();
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'run') return null;
    final payload = WidgetActionPayload.parse(call.arguments);
    if (payload == null) return false;

    try {
      await initializeSupabase();
    } catch (_) {
      // Already initialized in this isolate from an earlier tap.
    }

    await const WidgetActionHandler().handle(
      id: payload.id,
      source: payload.source,
      action: payload.action,
    );
    return true;
  });
  _channel.invokeMethod('ready');
}
