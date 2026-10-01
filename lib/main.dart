import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:inspire_blur/inspire_blur.dart';
import 'package:household_os/core/services/notification_service.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';
// Pulls widgetActionMain() into the compiled snapshot so the native
// DartEntrypoint-by-name lookup can resolve it; it is never called from here.
// ignore: unused_import
import 'package:household_os/core/services/widget_action_entrypoint.dart';
import 'app/app.dart';
import 'app/routing/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Preloads the top-status-bar-haze blur shader so it renders smoothly the
  // first time it's shown instead of on the initial frame.
  await Inspire.warmUp();
  // Edge-to-edge on Android 15+ and consistent system bar contrast on iOS.
  // Set once at startup; AppBarTheme carries the same style so it survives
  // scroll-under and route transitions.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(appSystemUiOverlayStyle);
  await initializeSupabase();
  await notificationService.initialize(
    onTap: (payload) {
      if (payload != null) appRouter.go('/homes/$payload/tasks');
    },
  );
  final pushService = RemotePushNotificationService();
  await pushService.initialize(onNavigate: appRouter.go);
  HomeWidget.widgetClicked.listen((_) => appRouter.go('/today'));
  runApp(ProviderScope(retry: noProviderRetry, child: const App()));
  _handleLaunchNotification();
  _handleRemoteLaunchTap(pushService);
  _handleWidgetLaunch();
}

/// Navigates using the remote push payload that cold-launched the app, if any.
Future<void> _handleRemoteLaunchTap(
  RemotePushNotificationService service,
) async {
  final payload = await service.getLaunchPayload();
  final route = payload?.route;
  if (route != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appRouter.go(route);
    });
  }
}

/// Navigates to the relevant Tasks screen when the app was launched by tapping
/// a notification. Deferred to post-frame so the router is ready.
Future<void> _handleLaunchNotification() async {
  final details = await notificationService.getLaunchDetails();
  if (details?.didNotificationLaunchApp == true) {
    final payload = details!.notificationResponse?.payload;
    if (payload != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        appRouter.go('/homes/$payload/tasks');
      });
    }
  }
}

/// Navigates to Today when the app was launched by tapping the home-screen
/// widget. Deferred to post-frame so the router is ready.
Future<void> _handleWidgetLaunch() async {
  final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
  if (uri != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appRouter.go('/today');
    });
  }
}
