package com.household.household_os

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent

class HouseholdOsWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            updateWidget(context, appWidgetManager, id)
        }
    }

    private fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        val sp = context.getSharedPreferences("HomeWidgetPlugin", Context.MODE_PRIVATE)
        val overdueCount = sp.getInt("widget_overdue_count", 0)
        val todayCount = sp.getInt("widget_today_count", 0)
        val privacy = sp.getString("widget_privacy", "counts_only") ?: "counts_only"
        val row0Title = sp.getString("widget_row_0_title", "") ?: ""
        val row0Detail = sp.getString("widget_row_0_detail", "") ?: ""
        val row1Title = sp.getString("widget_row_1_title", "") ?: ""
        val row1Detail = sp.getString("widget_row_1_detail", "") ?: ""
        val row2Title = sp.getString("widget_row_2_title", "") ?: ""
        val row2Detail = sp.getString("widget_row_2_detail", "") ?: ""

        val views = RemoteViews(context.packageName, R.layout.household_os_widget)

        // Summary line
        val summary = buildSummary(overdueCount, todayCount)
        views.setTextViewText(R.id.widget_summary, summary)

        // Tap the whole widget → open Today tab
        val launchIntent = HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("household_os://today"),
        )
        views.setOnClickPendingIntent(R.id.widget_root, launchIntent)

        val showNames = privacy == "show_names"
        val hasAny = overdueCount > 0 || todayCount > 0

        if (showNames) {
            bindRow(views, R.id.widget_row_0, R.id.widget_row_0_title, R.id.widget_row_0_detail, row0Title, row0Detail)
            bindRow(views, R.id.widget_row_1, R.id.widget_row_1_title, R.id.widget_row_1_detail, row1Title, row1Detail)
            bindRow(views, R.id.widget_row_2, R.id.widget_row_2_title, R.id.widget_row_2_detail, row2Title, row2Detail)
            val anyRow = row0Title.isNotEmpty() || row1Title.isNotEmpty() || row2Title.isNotEmpty()
            views.setViewVisibility(R.id.widget_empty, if (anyRow) View.GONE else View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_row_0, View.GONE)
            views.setViewVisibility(R.id.widget_row_1, View.GONE)
            views.setViewVisibility(R.id.widget_row_2, View.GONE)
            views.setViewVisibility(R.id.widget_empty, if (hasAny) View.GONE else View.VISIBLE)
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun bindRow(
        views: RemoteViews,
        rowId: Int,
        titleId: Int,
        detailId: Int,
        title: String,
        detail: String,
    ) {
        if (title.isNotEmpty()) {
            views.setViewVisibility(rowId, View.VISIBLE)
            views.setTextViewText(titleId, title)
            views.setTextViewText(detailId, detail)
        } else {
            views.setViewVisibility(rowId, View.GONE)
        }
    }

    private fun buildSummary(overdue: Int, today: Int): String {
        return when {
            overdue > 0 && today > 0 -> "$overdue overdue · $today today"
            overdue > 0 -> "$overdue overdue"
            today > 0 -> "$today today"
            else -> ""
        }
    }
}
