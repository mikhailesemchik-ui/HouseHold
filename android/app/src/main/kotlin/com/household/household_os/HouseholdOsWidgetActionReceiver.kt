package com.household.household_os

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * Receives a widget row's completion tap and hands it to [HouseholdOsWidgetActionWorker].
 * Does no network work itself — home_widget's own background dispatch
 * (registerInteractivityCallback) was traced and confirmed not to reach Dart
 * reliably in this project, so this is a small dedicated replacement for the
 * dispatch hop only; task business logic still lives entirely in Dart.
 */
class HouseholdOsWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val uri = intent.data ?: return
        if (uri.scheme != "household_os" || uri.host != "widget-action") return

        val id = uri.getQueryParameter("id")
        val source = uri.getQueryParameter("source")
        val action = uri.getQueryParameter("action")
        if (id.isNullOrEmpty()) return
        if (source != "occurrence" && source != "anytime") return
        if (action != "complete" && action != "reopen") return

        val appContext = context.applicationContext
        Log.d(TAG, "receiver reached id=${id.hashCode()} action=$action t=${System.currentTimeMillis()}")

        // Every delivered tap is accepted as the new latest desired state —
        // none are dropped, including while a mutation for an older desired
        // state is still running. A worker always re-reads this fresh at
        // execution time rather than trusting what triggered its enqueue,
        // so only the most recent tap's intent survives no matter how many
        // arrived in between.
        val revision = WidgetOptimisticOverlay.set(appContext, id, source, desiredCompleted = action == "complete")
        HouseholdOsWidgetProvider.refreshAll(appContext)
        Log.d(TAG, "optimistic refresh complete id=${id.hashCode()} rev=$revision t=${System.currentTimeMillis()}")

        val data = Data.Builder().putString(KEY_ID, id).build()
        val request = OneTimeWorkRequestBuilder<HouseholdOsWidgetActionWorker>()
            .setInputData(data)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.LINEAR, 10, TimeUnit.SECONDS)
            .build()

        // APPEND_OR_REPLACE chains this request after any work already
        // enqueued/running for the same id, rather than dropping it (KEEP)
        // or cancelling the in-flight one (REPLACE, which caused the
        // original cancellation-mid-mutation race). This is what prevents a
        // "lost wake-up": if a tap arrives while an older desired state is
        // still being reconciled, one more worker run is guaranteed to
        // happen afterward and pick up whatever is latest by then. Falls
        // back to starting a fresh chain (rather than never running at all)
        // if the previous chain ended in failure/cancellation.
        WorkManager.getInstance(appContext)
            .enqueueUniqueWork("widget_action_$id", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    companion object {
        const val KEY_ID = "id"
        private const val TAG = "WidgetAction"
    }
}
