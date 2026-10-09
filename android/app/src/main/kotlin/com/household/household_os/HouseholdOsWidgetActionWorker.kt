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

        // Re-read the desired state fresh, now — never trust what triggered
        // this particular enqueue. WorkManager may have chained several of
        // these (one per tap) via APPEND_OR_REPLACE; only the latest
        // desired state at the moment each one actually runs matters. If a
        // prior chained worker already reconciled this id (or nothing is
        // pending, or the entry expired), there is nothing to do — exit
        // before paying for a FlutterEngine boot.
        val entry = WidgetOptimisticOverlay.get(applicationContext, id)
        if (entry == null) {
            Log.d(TAG, "worker skip (nothing pending) id=${id.hashCode()} t=${System.currentTimeMillis()}")
            return Result.success()
        }

        Log.d(TAG, "worker start id=${id.hashCode()} rev=${entry.revision} t=${System.currentTimeMillis()}")
        val action = if (entry.desiredCompleted) "complete" else "reopen"
        val ok = runOnHeadlessEngine(id, entry.source, action)
        Log.d(TAG, "worker mutation id=${id.hashCode()} rev=${entry.revision} ok=$ok t=${System.currentTimeMillis()}")

        if (!ok && runAttemptCount < MAX_ATTEMPTS) {
            // Transient/ambiguous failure: leave the desired state in place
            // and let WorkManager's own backoff retry this same worker.
            // completeTask/reopenTask and the complete_occurrence/
            // reopen_occurrence RPCs are all idempotent target-state writes
            // (proven in
            // supabase/migrations/20260825000010_due_dates_and_recurrence.sql
            // — the RPCs explicitly no-op if already in the target state),
            // so retrying the same desired state is always safe regardless
            // of whether the failed attempt partially landed server-side.
            HouseholdOsWidgetProvider.refreshAll(applicationContext)
            return Result.retry()
        }

        // Either it succeeded, or we're giving up after MAX_ATTEMPTS —
        // either way this attempt's job is done. Only clear if nothing
        // newer arrived while this ran: an older worker must never discard
        // a desired state a later tap already wrote. If a newer revision
        // exists it is already chained (every tap enqueues) and will
        // reconcile itself.
        WidgetOptimisticOverlay.clearIfRevisionMatches(applicationContext, id, entry.revision)
        // Dart already wrote the fresh snapshot and sent home_widget's own
        // ACTION_APPWIDGET_UPDATE self-broadcast, but that broadcast was
        // observed (physical-device logcat) to never arrive while this
        // process has no foreground UI — refresh directly, in-process, so
        // the widget doesn't depend on a hop that can be deferred.
        HouseholdOsWidgetProvider.refreshAll(applicationContext)
        Log.d(TAG, "worker done id=${id.hashCode()} rev=${entry.revision} ok=$ok t=${System.currentTimeMillis()}")
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

        /** Bounded retry count for a failed mutation — see doWork(). */
        private const val MAX_ATTEMPTS = 3
    }
}
