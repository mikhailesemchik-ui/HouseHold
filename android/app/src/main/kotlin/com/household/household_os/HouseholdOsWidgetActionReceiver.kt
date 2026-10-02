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

        val data = Data.Builder()
            .putString(KEY_ID, id)
            .putString(KEY_SOURCE, source)
            .putString(KEY_ACTION, action)
            .build()
        val request = OneTimeWorkRequestBuilder<HouseholdOsWidgetActionWorker>()
            .setInputData(data)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()

        Log.d(TAG, "receiver reached id=${id.hashCode()} action=$action t=${System.currentTimeMillis()}")

        // One in-flight job per task/occurrence id: KEEP means a tap that
        // arrives while the previous one for the same id is still
        // enqueued/running is dropped rather than cancelling/restarting it.
        // Once that work reaches a terminal state, the next tap starts a
        // fresh one. REPLACE previously let repeated taps cancel the
        // in-flight worker (and its headless engine) mid-mutation.
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork("widget_action_$id", ExistingWorkPolicy.KEEP, request)
    }

    companion object {
        const val KEY_ID = "id"
        const val KEY_SOURCE = "source"
        const val KEY_ACTION = "action"
        private const val TAG = "WidgetAction"
    }
}
