import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var apnsToken: String?
    private var pendingLaunchPayload: [String: Any?]?
    private var pushNotifChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            FlutterMethodChannel(
                name: "household_os/push_token",
                binaryMessenger: controller.binaryMessenger
            ).setMethodCallHandler { [weak self] call, result in
                if call.method == "getPushToken" {
                    result(self?.apnsToken)
                } else {
                    result(FlutterMethodNotImplemented)
                }
            }

            let notifChannel = FlutterMethodChannel(
                name: "household_os/push_notifications",
                binaryMessenger: controller.binaryMessenger
            )
            pushNotifChannel = notifChannel
            notifChannel.setMethodCallHandler { [weak self] call, result in
                if call.method == "getLaunchPayload" {
                    result(self?.pendingLaunchPayload)
                    self?.pendingLaunchPayload = nil
                } else {
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()

        // Capture cold-launch notification payload for later retrieval
        if let remoteNotif = launchOptions?[.remoteNotification] as? [String: Any] {
            pendingLaunchPayload = extractPayload(from: remoteNotif)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Let super handle local notifications and call completionHandler
        super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)

        // Only handle remote push notifications for navigation
        guard response.notification.request.trigger is UNPushNotificationTrigger else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let payload = extractPayload(from: userInfo as? [String: Any] ?? [:]) else { return }

        if let channel = pushNotifChannel {
            channel.invokeMethod("notificationTapped", arguments: payload)
        } else {
            pendingLaunchPayload = payload
        }
    }

    // Extracts structured navigation payload from a remote notification's userInfo.
    // The Edge Function sets the "payload" key with type, householdId, taskId.
    private func extractPayload(from userInfo: [String: Any]) -> [String: Any?]? {
        guard let payload = userInfo["payload"] as? [String: Any],
              let type = payload["type"] as? String, !type.isEmpty else { return nil }
        var result: [String: Any?] = ["type": type]
        if let householdId = payload["householdId"] as? String { result["householdId"] = householdId }
        if let taskId = payload["taskId"] as? String { result["taskId"] = taskId }
        return result
    }
}
