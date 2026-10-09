package com.household.household_os

import android.content.Context
import android.content.Intent
import android.graphics.Paint
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
        // The snapshot's label is always the item's real due-bucket
        // (Overdue/Today/Anytime/a date), independent of completed status
        // (see widget_snapshot.dart's _dueLabelFor) — so flipping
        // `completed` alone is enough for either direction to immediately
        // show its correct real status, with no placeholder state needed.
        val item = if (entry == null) {
            task.toRenderTask()
        } else {
            task.toRenderTask(completedOverride = entry.desiredCompleted)
        }
        if (item.completed) completed.add(item) else active.add(item)
    }
    return active + completed
}

private fun JSONObject.toRenderTask(completedOverride: Boolean? = null): RenderTask = RenderTask(
    id = optString("id"),
    source = optString("source"),
    title = optString("title"),
    household = optString("household"),
    label = optString("label"),
    completed = completedOverride ?: optBoolean("completed", false),
)

/** Stable per-row id, shared by both collection-delivery paths. */
fun stableTaskItemId(id: String): Long = id.hashCode().toLong()

private const val COLOR_TITLE = 0xFF20231F.toInt()
private const val COLOR_TITLE_MUTED = 0xFF747A72.toInt()
private const val COLOR_OVERDUE_TEXT = 0xFFC96F66.toInt()
private const val COLOR_SAGE_TEXT = 0xFF50674E.toInt()
private const val COLOR_NEUTRAL_TEXT = 0xFF5C5F55.toInt()
private const val COLOR_COMPLETED_TEXT = 0xFF747A72.toInt()

/** Builds one row's RemoteViews — identical rendering for both collection-delivery paths. */
fun buildTaskRowRemoteViews(context: Context, task: RenderTask, compact: Boolean): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.household_os_widget_row)
    val isOverdue = !task.completed && task.label == "Overdue"

    views.setTextViewText(R.id.row_title, task.title)
    views.setTextColor(R.id.row_title, if (task.completed) COLOR_TITLE_MUTED else COLOR_TITLE)
    // setPaintFlags *replaces* the flags, rather than toggling a bit, so a
    // recycled row (legacy RemoteViewsFactory path) can't keep a stale
    // strikethrough from whatever it last rendered.
    views.setInt(
        R.id.row_title,
        "setPaintFlags",
        if (task.completed) {
            Paint.ANTI_ALIAS_FLAG or Paint.STRIKE_THRU_TEXT_FLAG
        } else {
            Paint.ANTI_ALIAS_FLAG
        },
    )

    val checkBg = when {
        task.completed -> R.drawable.widget_check_circle_completed
        isOverdue -> R.drawable.widget_check_circle_overdue
        else -> R.drawable.widget_check_circle_active
    }
    val checkIcon = when {
        task.completed -> R.drawable.ic_widget_check
        isOverdue -> R.drawable.ic_widget_ring_overdue
        else -> R.drawable.ic_widget_circle
    }
    views.setInt(R.id.row_check_target, "setBackgroundResource", checkBg)
    views.setImageViewResource(R.id.row_check, checkIcon)

    if (compact) {
        views.setViewVisibility(R.id.row_household_row, View.GONE)
    } else {
        views.setViewVisibility(R.id.row_household_row, View.VISIBLE)
        views.setTextViewText(R.id.row_detail, task.household)
    }

    val pillText: String
    val pillBg: Int
    val pillTextColor: Int
    when {
        task.completed -> {
            pillText = "Completed"
            pillBg = R.drawable.widget_pill_completed
            pillTextColor = COLOR_COMPLETED_TEXT
        }
        isOverdue -> {
            pillText = "Overdue"
            pillBg = R.drawable.widget_pill_overdue
            pillTextColor = COLOR_OVERDUE_TEXT
        }
        task.label == "Today" -> {
            pillText = "Today"
            pillBg = R.drawable.widget_pill_sage
            pillTextColor = COLOR_SAGE_TEXT
        }
        else -> {
            // "Anytime" or a short upcoming date (e.g. "Mon 5 Oct") — shown
            // verbatim so a real due date is never silently replaced with a
            // generic label.
            pillText = task.label
            pillBg = R.drawable.widget_pill_neutral
            pillTextColor = COLOR_NEUTRAL_TEXT
        }
    }
    views.setViewVisibility(R.id.row_status_pill, View.VISIBLE)
    views.setTextViewText(R.id.row_status_pill, pillText)
    views.setInt(R.id.row_status_pill, "setBackgroundResource", pillBg)
    views.setTextColor(R.id.row_status_pill, pillTextColor)

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
