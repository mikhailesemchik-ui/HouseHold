package com.household.household_os

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject

/** Backs the scrollable task list inside the Android home-screen widget. */
class HouseholdOsWidgetRemoteViewsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return HouseholdOsWidgetRemoteViewsFactory(applicationContext, intent)
    }

    companion object {
        const val EXTRA_COMPACT = "household_os_widget_compact"
    }
}

private class HouseholdOsWidgetRemoteViewsFactory(
    private val context: Context,
    intent: Intent,
) : RemoteViewsService.RemoteViewsFactory {

    private val compact = intent.getBooleanExtra(
        HouseholdOsWidgetRemoteViewsService.EXTRA_COMPACT,
        false,
    )
    private var tasks: List<JSONObject> = emptyList()

    override fun onCreate() {
        loadTasks()
    }

    override fun onDataSetChanged() {
        loadTasks()
    }

    override fun onDestroy() {
        tasks = emptyList()
    }

    override fun getCount(): Int = tasks.size

    override fun getViewAt(position: Int): RemoteViews {
        val task = tasks[position]
        val views = RemoteViews(context.packageName, R.layout.household_os_widget_row)

        views.setTextViewText(R.id.row_title, task.optString("title"))
        val completed = task.optBoolean("completed", false)
        views.setImageViewResource(
            R.id.row_check,
            if (completed) R.drawable.ic_widget_check else R.drawable.ic_widget_circle,
        )

        if (compact) {
            views.setViewVisibility(R.id.row_detail, android.view.View.GONE)
        } else {
            views.setViewVisibility(R.id.row_detail, android.view.View.VISIBLE)
            val household = task.optString("household")
            val label = task.optString("label")
            views.setTextViewText(R.id.row_detail, "$household · $label")
        }

        val action = if (completed) "reopen" else "complete"
        val uri = Uri.parse(
            "household_os://widget-action" +
                "?id=${Uri.encode(task.optString("id"))}" +
                "&source=${Uri.encode(task.optString("source"))}" +
                "&action=$action",
        )
        val fillInIntent = Intent()
        fillInIntent.data = uri
        views.setOnClickFillInIntent(R.id.row_check_target, fillInIntent)

        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = tasks[position].optString("id").hashCode().toLong()

    override fun hasStableIds(): Boolean = true

    private fun loadTasks() {
        val base = try {
            val sp = HomeWidgetPlugin.getData(context)
            val raw = sp.getString(PREF_KEY, null)
            if (raw == null) {
                emptyList()
            } else {
                val root = JSONObject(raw)
                if (root.optString("privacy", "counts_only") != "show_names") {
                    emptyList()
                } else {
                    val array: JSONArray = root.optJSONArray("tasks") ?: JSONArray()
                    (0 until array.length()).map { array.getJSONObject(it) }
                }
            }
        } catch (e: Exception) {
            emptyList()
        }
        tasks = applyOptimisticOverlay(base)
    }

    /**
     * Renders each row as if its pending complete/reopen action had already
     * landed, grouping optimistically-completed rows after the active ones
     * and optimistically-reopened rows back among the active ones. The
     * authoritative snapshot (and its true per-item ordering) is untouched —
     * this only reorders the in-memory render list for the few seconds a
     * mutation is in flight, so the true order reasserts itself the moment
     * the overlay clears and the next authoritative refresh runs.
     */
    private fun applyOptimisticOverlay(base: List<JSONObject>): List<JSONObject> {
        val overlay = WidgetOptimisticOverlay.snapshot(context)
        if (overlay.isEmpty()) return base

        val active = mutableListOf<JSONObject>()
        val completed = mutableListOf<JSONObject>()
        for (task in base) {
            val entry = overlay[task.optString("id")]
            if (entry == null) {
                if (task.optBoolean("completed", false)) completed.add(task) else active.add(task)
                continue
            }
            val rendered = JSONObject(task.toString())
            rendered.put("completed", entry.targetCompleted)
            if (entry.targetCompleted) {
                rendered.put("label", "Done")
                completed.add(rendered)
            } else {
                active.add(rendered)
            }
        }
        return active + completed
    }

    companion object {
        const val PREF_KEY = "widget_snapshot_json"
    }
}
