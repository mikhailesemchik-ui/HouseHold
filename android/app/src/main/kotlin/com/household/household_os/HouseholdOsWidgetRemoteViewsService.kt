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
        tasks = try {
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
    }

    companion object {
        const val PREF_KEY = "widget_snapshot_json"
    }
}
