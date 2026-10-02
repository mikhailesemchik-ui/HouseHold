package com.household.household_os

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService

/**
 * Backs the scrollable task list inside the Android home-screen widget on
 * API < 31, where [RemoteViews.RemoteCollectionItems] isn't available.
 * Row content comes from [loadRenderableTasks] / [buildTaskRowRemoteViews] —
 * the same renderer the API 31+ direct-collection path in
 * HouseholdOsWidgetProvider uses, so ordering/overlay logic exists once.
 */
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
    private var tasks: List<RenderTask> = emptyList()

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

    override fun getViewAt(position: Int): RemoteViews =
        buildTaskRowRemoteViews(context, tasks[position], compact)

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = stableTaskItemId(tasks[position].id)

    override fun hasStableIds(): Boolean = true

    private fun loadTasks() {
        tasks = loadRenderableTasks(context)
    }
}
