package com.household.household_os

import android.content.Intent
import android.os.Bundle
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val pushTokenChannel = "household_os/push_token"
    private val pushNotifChannel = "household_os/push_notifications"
    private var notifChannel: MethodChannel? = null
    private var pendingLaunchPayload: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pushTokenChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPushToken" -> FirebaseMessaging.getInstance().token
                        .addOnSuccessListener { result.success(it) }
                        .addOnFailureListener { result.error("TOKEN_ERROR", it.message, null) }
                    else -> result.notImplemented()
                }
            }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pushNotifChannel)
        notifChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchPayload" -> {
                    result.success(pendingLaunchPayload)
                    pendingLaunchPayload = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLaunchPayload = extractNotificationPayload(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val payload = extractNotificationPayload(intent) ?: return
        val channel = notifChannel
        if (channel != null) {
            channel.invokeMethod("notificationTapped", payload)
        } else {
            pendingLaunchPayload = payload
        }
    }

    private fun extractNotificationPayload(intent: Intent?): Map<String, Any?>? {
        val type = intent?.getStringExtra("type") ?: return null
        val payload = mutableMapOf<String, Any?>("type" to type)
        intent.getStringExtra("householdId")?.let { payload["householdId"] = it }
        intent.getStringExtra("taskId")?.let { payload["taskId"] = it }
        return payload
    }
}
