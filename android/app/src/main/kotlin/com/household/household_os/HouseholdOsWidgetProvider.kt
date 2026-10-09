package com.household.household_os

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.app.PendingIntent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/** Compact row layout kicks in below this widget height, to fit more rows. */
private const val COMPACT_HEIGHT_DP = 180

class HouseholdOsWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        Log.d(TAG, "onUpdate ids=${appWidgetIds.toList()} t=${System.currentTimeMillis()}")
        for (id in appWidgetIds) {
            updateWidget(context, appWidgetManager, id)
        }
    }

    companion object {
        private const val TAG = "WidgetAction"

        /**
         * Rebuilds and pushes RemoteViews for every placed instance of this
         * widget, in-process. [HomeWidgetPlugin]'s own `updateWidget` does
         * this by having the app send itself an ACTION_APPWIDGET_UPDATE
         * broadcast; on Samsung that self-broadcast was observed to be
         * deferred indefinitely by One UI's background standby-bucket
         * throttling once the process has no foreground UI (confirmed via
         * physical-device logcat: the broadcast never reached onUpdate after
         * a successful widget-triggered mutation). Calling this directly
         * from the worker that just finished the mutation skips that
         * broadcast hop entirely — same rendering code, no indirection to
         * get deferred.
         */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                android.content.ComponentName(context, HouseholdOsWidgetProvider::class.java),
            )
            val provider = HouseholdOsWidgetProvider()
            for (id in ids) {
                provider.updateWidget(context, manager, id)
            }
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    private fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        val sp = HomeWidgetPlugin.getData(context)
        val raw = sp.getString("widget_snapshot_json", null)
        val root = if (raw != null) JSONObject(raw) else JSONObject()
        val showNames = root.optString("privacy", "counts_only") == "show_names"

        // In show_names mode, task-level data is available locally, so the
        // header reuses the same optimistic-overlay-adjusted list the row
        // collection renders from — counting it directly means the header
        // always describes the same state the rows already show, instead of
        // lagging a refresh cycle behind on the raw authoritative counts.
        // counts_only mode never stores task-level data (nothing is tappable
        // there either), so there is nothing to adjust and the authoritative
        // snapshot counts are used as-is.
        val renderTasks = if (showNames) loadRenderableTasks(context) else emptyList()
        val activeCount: Int
        val completedTodayCount: Int
        if (showNames) {
            activeCount = renderTasks.count { !it.completed }
            completedTodayCount = renderTasks.count { it.completed }
        } else {
            // Additive snapshot fields; a stale cached snapshot written
            // before they existed just reads 0.
            activeCount = root.optInt("activeCount", 0)
            completedTodayCount = root.optInt("completedTodayCount", 0)
        }

        val views = RemoteViews(context.packageName, R.layout.household_os_widget)

        views.setTextViewText(R.id.widget_summary, buildSummary(activeCount, completedTodayCount))

        val launchIntent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("household_os://today"),
        )
        views.setOnClickPendingIntent(R.id.widget_header_click, launchIntent)

        val compact = isCompact(appWidgetManager, appWidgetId)
        views.setEmptyView(R.id.widget_list, R.id.widget_empty)
        views.setPendingIntentTemplate(R.id.widget_list, actionPendingIntentTemplate(context))

        if (Build.VERSION.SDK_INT >= 31) {
            // The reordered collection rides in this same RemoteViews update,
            // so the checkbox state and the row's new position arrive in one
            // paint — notifyAppWidgetViewDataChanged() below is the legacy
            // path's async invalidate-then-refetch, which visibly leaves the
            // old row order on screen for a beat while the launcher re-queries
            // the factory; a direct collection has no such second stage.
            val items = RemoteViews.RemoteCollectionItems.Builder()
                .setHasStableIds(true)
                .setViewTypeCount(1)
            for (task in renderTasks) {
                items.addItem(stableTaskItemId(task.id), buildTaskRowRemoteViews(context, task, compact))
            }
            views.setRemoteAdapter(R.id.widget_list, items.build())
        } else {
            val adapterIntent = Intent(context, HouseholdOsWidgetRemoteViewsService::class.java)
            // The compact flag is encoded into the data URI, not just as an
            // extra: Intent equality for RemoteViewsFactory caching ignores
            // extras, so a same-URI intent would keep reusing a factory built
            // with the old compact value and never reflect a resize.
            adapterIntent.data = Uri.parse(
                "household-os-widget://adapter/$appWidgetId?compact=$compact",
            )
            adapterIntent.putExtra(HouseholdOsWidgetRemoteViewsService.EXTRA_COMPACT, compact)
            views.setRemoteAdapter(R.id.widget_list, adapterIntent)
        }

        if (showNames) {
            views.setViewVisibility(R.id.widget_list, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty, "Nothing assigned.")
        } else {
            // Privacy mode hides task details: the list stays empty (the
            // factory itself returns zero rows), only the summary line shows.
            views.setViewVisibility(R.id.widget_list, View.GONE)
            views.setTextViewText(
                R.id.widget_empty,
                if (activeCount > 0) "" else "Nothing due.",
            )
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
        if (Build.VERSION.SDK_INT < 31) {
            // The API 31+ path above already carries the full, reordered
            // collection inside the updateAppWidget() call — nothing left to
            // invalidate.
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        }
        Log.d(TAG, "widget refresh complete id=$appWidgetId t=${System.currentTimeMillis()}")
    }

    /**
     * A mutable broadcast template targeting our own
     * [HouseholdOsWidgetActionReceiver], so each row's fill-in intent (its
     * task id/action, set as the intent data) actually merges in at click
     * time. A `FLAG_IMMUTABLE` PendingIntent silently drops a RemoteViews
     * collection's per-row fill-in data — this must stay mutable.
     */
    private fun actionPendingIntentTemplate(context: Context): PendingIntent {
        val intent = Intent(context, HouseholdOsWidgetActionReceiver::class.java)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 31) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        return PendingIntent.getBroadcast(context, 0, intent, flags)
    }

    private fun isCompact(appWidgetManager: AppWidgetManager, appWidgetId: Int): Boolean {
        val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
        val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        return minHeight in 1 until COMPACT_HEIGHT_DP
    }

    private fun buildSummary(active: Int, completedToday: Int): String {
        return when {
            active > 0 && completedToday > 0 -> "$active to do · $completedToday completed"
            active > 0 -> "$active to do"
            completedToday > 0 -> "All caught up · $completedToday completed"
            else -> "All caught up"
        }
    }
}
