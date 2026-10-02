package com.household.household_os

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * Boots a headless Flutter engine at the dedicated `widgetActionMain` entrypoint
 * (declared in lib/core/services/widget_action_entrypoint.dart) and hands it
 * one task/occurrence action. Does not run the app's main() or any UI.
 */
class HouseholdOsWidgetActionWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val id = inputData.getString(HouseholdOsWidgetActionReceiver.KEY_ID) ?: return Result.failure()
        val source = inputData.getString(HouseholdOsWidgetActionReceiver.KEY_SOURCE) ?: return Result.failure()
        val action = inputData.getString(HouseholdOsWidgetActionReceiver.KEY_ACTION) ?: return Result.failure()

        Log.d(TAG, "worker start id=${id.hashCode()} t=${System.currentTimeMillis()}")
        val ok = runOnHeadlessEngine(id, source, action)
        if (ok) {
            // Dart already wrote the fresh snapshot and sent home_widget's own
            // ACTION_APPWIDGET_UPDATE self-broadcast, but that broadcast was
            // observed (physical-device logcat) to never arrive while this
            // process has no foreground UI — refresh directly, in-process, so
            // the widget doesn't depend on a hop that can be deferred.
            HouseholdOsWidgetProvider.refreshAll(applicationContext)
        }
        Log.d(TAG, "worker done id=${id.hashCode()} ok=$ok t=${System.currentTimeMillis()}")
        return if (ok) Result.success() else Result.failure()
    }

    private suspend fun runOnHeadlessEngine(id: String, source: String, action: String): Boolean =
        withContext(Dispatchers.Main) {
            val loader = FlutterLoader()
            if (!loader.initialized()) {
                loader.startInitialization(applicationContext)
            }
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)
            // Required for a manually-created headless engine: unlike the
            // FlutterActivity-owned engine (which registers plugins itself),
            // this one would otherwise have no native handler for the
            // home_widget / shared_preferences channels, so those calls in
            // WidgetActionHandler would throw MissingPluginException and the
            // snapshot/RemoteViews refresh would silently never happen.
            GeneratedPluginRegistrant.registerWith(engine)
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)

            val result = suspendCancellableCoroutine<Boolean> { cont ->
                // Dart calls "ready" once widgetActionMain() has set its handler up;
                // only then is it safe to send it the actual action.
                channel.setMethodCallHandler { call, resultCallback ->
                    if (call.method == "ready") {
                        Log.d(TAG, "dart ready id=${id.hashCode()} t=${System.currentTimeMillis()}")
                        channel.invokeMethod(
                            "run",
                            mapOf("id" to id, "source" to source, "action" to action),
                            object : MethodChannel.Result {
                                override fun success(result: Any?) {
                                    Log.d(TAG, "dart run success id=${id.hashCode()} t=${System.currentTimeMillis()}")
                                    if (cont.isActive) cont.resume(result == true)
                                }

                                override fun error(code: String, message: String?, details: Any?) {
                                    Log.d(TAG, "dart run error id=${id.hashCode()} code=$code msg=$message")
                                    if (cont.isActive) cont.resume(false)
                                }

                                override fun notImplemented() {
                                    if (cont.isActive) cont.resume(false)
                                }
                            },
                        )
                        resultCallback.success(null)
                    } else {
                        resultCallback.notImplemented()
                    }
                }

                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "package:household_os/core/services/widget_action_entrypoint.dart",
                        "widgetActionMain",
                    ),
                )

                cont.invokeOnCancellation { engine.destroy() }
            }

            engine.destroy()
            result
        }

    companion object {
        private const val CHANNEL = "com.household.household_os/widget_action"
        private const val TAG = "WidgetAction"
    }
}
