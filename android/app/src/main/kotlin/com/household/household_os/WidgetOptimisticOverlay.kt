package com.household.household_os

import android.content.Context
import org.json.JSONObject

/**
 * Short-lived, self-healing presentation overlay for a widget row with a
 * complete/reopen action pending. Never authoritative — Dart's snapshot
 * remains the single source of truth; this exists only so the widget can
 * respond before the headless engine boots and the backend mutation lands.
 *
 * Every entry expires on its own after [EXPIRY_MS]. This is deliberate:
 * an earlier Dart-side "in-flight" guard got permanently stuck once and
 * blocked a task forever (see widget_action_handler.dart history) — nothing
 * here may ever do that. A read past expiry prunes the entry and behaves as
 * if it never existed, so a crashed/killed worker can never leave a row
 * stuck.
 */
object WidgetOptimisticOverlay {
    private const val PREFS_NAME = "widget_optimistic_overlay"
    private const val KEY_ENTRIES = "entries"
    private const val EXPIRY_MS = 15_000L

    data class Entry(val targetCompleted: Boolean)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** The still-valid pending entry for [id], or null if none or expired. */
    @Synchronized
    fun get(context: Context, id: String): Entry? = snapshot(context)[id]

    /** Records a new pending optimistic target for [id]. */
    @Synchronized
    fun set(context: Context, id: String, targetCompleted: Boolean) {
        val p = prefs(context)
        val root = JSONObject(p.getString(KEY_ENTRIES, null) ?: "{}")
        val entry = JSONObject()
        entry.put("targetCompleted", targetCompleted)
        entry.put("startedAt", System.currentTimeMillis())
        root.put(id, entry)
        p.edit().putString(KEY_ENTRIES, root.toString()).apply()
    }

    /** Clears the overlay for [id] once the authoritative result is known. */
    @Synchronized
    fun clear(context: Context, id: String) {
        val p = prefs(context)
        val raw = p.getString(KEY_ENTRIES, null) ?: return
        val root = JSONObject(raw)
        if (root.has(id)) {
            root.remove(id)
            p.edit().putString(KEY_ENTRIES, root.toString()).apply()
        }
    }

    /** All still-valid entries, opportunistically pruning expired ones. */
    @Synchronized
    fun snapshot(context: Context): Map<String, Entry> {
        val p = prefs(context)
        val raw = p.getString(KEY_ENTRIES, null) ?: return emptyMap()
        val root = JSONObject(raw)
        val now = System.currentTimeMillis()
        val result = mutableMapOf<String, Entry>()
        var changed = false
        for (key in root.keys().asSequence().toList()) {
            val obj = root.optJSONObject(key) ?: continue
            val startedAt = obj.optLong("startedAt", 0L)
            if (now - startedAt > EXPIRY_MS) {
                root.remove(key)
                changed = true
            } else {
                result[key] = Entry(obj.optBoolean("targetCompleted"))
            }
        }
        if (changed) {
            p.edit().putString(KEY_ENTRIES, root.toString()).apply()
        }
        return result
    }
}
