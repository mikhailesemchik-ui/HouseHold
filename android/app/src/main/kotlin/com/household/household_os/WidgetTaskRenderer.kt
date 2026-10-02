package com.household.household_os

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject

private const val PREF_KEY = "widget_snapshot_json"

/** One row of the widget's task list, after the optimistic overlay (if any) has been applied. */
data class RenderTask(
    val id: String,
    val source: String,
    val title: String,
    val household: String,
    val label: String,
    val completed: Boolean,
)

/**
 * Parses the authoritative Dart snapshot and applies [WidgetOptimisticOverlay]
 * on top, returning the final ordered row list (active rows, then completed).
 * The single source both collection-delivery paths (API 31+'s direct
 * RemoteCollectionItems and the legacy RemoteViewsFactory) render from, so
 * snapshot parsing, overlay application and grouping exist exactly once.
 */
fun loadRenderableTasks(context: Context): List<RenderTask> {
    val base = try {
        val sp = HomeWidgetPlugin.getData(context)
        val raw = sp.getString(PREF_KEY, null) ?: return emptyList()
        val root = JSONObject(raw)
        if (root.optString("privacy", "counts_only") != "show_names") return emptyList()
        val array: JSONArray = root.optJSONArray("tasks") ?: JSONArray()
        (0 until array.length()).map { array.getJSONObject(it) }
    } catch (e: Exception) {
        emptyList()
    }
    return applyOptimisticOverlay(context, base)
}

/**
 * Renders each row as if its pending complete/reopen action had already
 * landed, grouping optimistically-completed rows after the active ones and
 * optimistically-reopened rows back among the active ones. The authoritative
 * snapshot (and its true per-item ordering) is untouched — this only reorders
 * the in-memory render list for the few seconds a mutation is in flight, so
 * the true order reasserts itself the moment the overlay clears and the next
 * authoritative refresh runs.
 */
private fun applyOptimisticOverlay(context: Context, base: List<JSONObject>): List<RenderTask> {
    val overlay = WidgetOptimisticOverlay.snapshot(context)
    val active = mutableListOf<RenderTask>()
    val completed = mutableListOf<RenderTask>()
    for (task in base) {
        val entry = overlay[task.optString("id")]
        val item = when {
            entry == null -> task.toRenderTask()
            entry.targetCompleted -> task.toRenderTask(completedOverride = true, labelOverride = "Done")
            else -> task.toRenderTask(completedOverride = false)
        }
        if (item.completed) completed.add(item) else active.add(item)
    }
    return active + completed
}

private fun JSONObject.toRenderTask(
    completedOverride: Boolean? = null,
    labelOverride: String? = null,
): RenderTask = RenderTask(
    id = optString("id"),
    source = optString("source"),
    title = optString("title"),
    household = optString("household"),
    label = labelOverride ?: optString("label"),
    completed = completedOverride ?: optBoolean("completed", false),
)

/** Stable per-row id, shared by both collection-delivery paths. */
fun stableTaskItemId(id: String): Long = id.hashCode().toLong()

/** Builds one row's RemoteViews — identical rendering for both collection-delivery paths. */
fun buildTaskRowRemoteViews(context: Context, task: RenderTask, compact: Boolean): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.household_os_widget_row)

    views.setTextViewText(R.id.row_title, task.title)
    views.setImageViewResource(
        R.id.row_check,
        if (task.completed) R.drawable.ic_widget_check else R.drawable.ic_widget_circle,
    )

    if (compact) {
        views.setViewVisibility(R.id.row_detail, View.GONE)
    } else {
        views.setViewVisibility(R.id.row_detail, View.VISIBLE)
        views.setTextViewText(R.id.row_detail, "${task.household} · ${task.label}")
    }

    val action = if (task.completed) "reopen" else "complete"
    val uri = Uri.parse(
        "household_os://widget-action" +
            "?id=${Uri.encode(task.id)}" +
            "&source=${Uri.encode(task.source)}" +
            "&action=$action",
    )
    val fillInIntent = Intent()
    fillInIntent.data = uri
    views.setOnClickFillInIntent(R.id.row_check_target, fillInIntent)

    return views
}
