package com.household.household_os

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager

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

        // A tap on an item that already has a live optimistic action pending
        // is dropped here, before any native work: WorkManager's KEEP would
        // also refuse a duplicate job, but without this check the row would
        // still flip visually on every repeat tap. The target never changes
        // once set — it only clears when the worker's result is known or the
        // entry expires.
        if (WidgetOptimisticOverlay.get(appContext, id) != null) {
            Log.d(TAG, "ignored: optimistic action already pending id=${id.hashCode()}")
            return
        }

        // Presentation only — the row renders as if the mutation already
        // landed, immediately, no FlutterEngine/network wait. Dart's
        // snapshot stays the authoritative source; this is reconciled away
        // by the worker once the real result is known.
        WidgetOptimisticOverlay.set(appContext, id, targetCompleted = action == "complete")
        HouseholdOsWidgetProvider.refreshAll(appContext)
        Log.d(TAG, "optimistic refresh complete id=${id.hashCode()} t=${System.currentTimeMillis()}")

        val data = Data.Builder()
            .putString(KEY_ID, id)
            .putString(KEY_SOURCE, source)
            .putString(KEY_ACTION, action)
            .build()
        val request = OneTimeWorkRequestBuilder<HouseholdOsWidgetActionWorker>()
            .setInputData(data)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()

        // One in-flight job per task/occurrence id: KEEP means a tap that
        // arrives while the previous one for the same id is still
        // enqueued/running is dropped rather than cancelling/restarting it.
        // Once that work reaches a terminal state, the next tap starts a
        // fresh one. REPLACE previously let repeated taps cancel the
        // in-flight worker (and its headless engine) mid-mutation.
        WorkManager.getInstance(appContext)
            .enqueueUniqueWork("widget_action_$id", ExistingWorkPolicy.KEEP, request)
    }

    companion object {
        const val KEY_ID = "id"
        const val KEY_SOURCE = "source"
        const val KEY_ACTION = "action"
        private const val TAG = "WidgetAction"
    }
}
