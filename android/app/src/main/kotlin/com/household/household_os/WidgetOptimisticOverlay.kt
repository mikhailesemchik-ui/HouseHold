package com.household.household_os

import android.content.Context
import org.json.JSONObject

/**
 * Short-lived, self-healing per-item "latest desired state" for the widget's
 * complete/reopen interaction. Never authoritative — Dart's snapshot remains
 * the single source of truth; this exists so the widget can respond
 * immediately (before the headless engine boots and the backend mutation
 * lands) and so every tap is accepted rather than only the first one while a
 * mutation is pending.
 *
 * Each entry carries a monotonically increasing [Entry.revision]. A worker
 * that reconciles an older revision must never clear a newer one a later tap
 * already wrote — see [clearIfRevisionMatches]. This is what lets repeated
 * taps coalesce into the fewest backend mutations without ever losing the
 * user's final intent.
 *
 * Every entry expires on its own after [EXPIRY_MS]. This is deliberate: an
 * earlier Dart-side "in-flight" guard got permanently stuck once and blocked
 * a task forever (see widget_action_handler.dart history) — nothing here may
 * ever do that. A read past expiry prunes the entry and behaves as if it
 * never existed, so a crashed/killed worker (or a backend that never
 * recovers) can never leave a row stuck. The window is sized to comfortably
 * outlive HouseholdOsWidgetActionWorker's own bounded retry/backoff, so a
 * legitimate retry in flight is never pre-empted by expiry.
 */
object WidgetOptimisticOverlay {
    private const val PREFS_NAME = "widget_optimistic_overlay"
    private const val KEY_ENTRIES = "entries"
    private const val EXPIRY_MS = 120_000L

    data class Entry(
        val source: String,
        val desiredCompleted: Boolean,
        val revision: Long,
    )

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** The still-live desired state for [id], or null if none or expired. */
    @Synchronized
    fun get(context: Context, id: String): Entry? = snapshot(context)[id]

    /**
     * Records the latest desired state for [id], superseding whatever was
     * pending before. Always accepted — this never drops a tap. Returns the
     * new entry's revision, so the caller can log it.
     */
    @Synchronized
    fun set(context: Context, id: String, source: String, desiredCompleted: Boolean): Long {
        val p = prefs(context)
        val root = JSONObject(p.getString(KEY_ENTRIES, null) ?: "{}")
        val previousRevision = root.optJSONObject(id)?.optLong("revision", 0L) ?: 0L
        val newRevision = previousRevision + 1
        val entry = JSONObject()
        entry.put("source", source)
        entry.put("desiredCompleted", desiredCompleted)
        entry.put("revision", newRevision)
        entry.put("updatedAt", System.currentTimeMillis())
        root.put(id, entry)
        p.edit().putString(KEY_ENTRIES, root.toString()).apply()
        return newRevision
    }

    /**
     * Clears the overlay for [id] only if it is still at [revision] — a
     * worker that reconciled an older revision must not discard a newer one
     * a later tap already wrote (that newer revision is always already
     * chained behind this worker via `ExistingWorkPolicy.APPEND_OR_REPLACE`
     * and will reconcile itself). Returns true if it actually cleared.
     */
    @Synchronized
    fun clearIfRevisionMatches(context: Context, id: String, revision: Long): Boolean {
        val p = prefs(context)
        val raw = p.getString(KEY_ENTRIES, null) ?: return false
        val root = JSONObject(raw)
        val existing = root.optJSONObject(id) ?: return false
        if (existing.optLong("revision", -1L) != revision) return false
        root.remove(id)
        p.edit().putString(KEY_ENTRIES, root.toString()).apply()
        return true
    }

    /** All still-live entries, opportunistically pruning expired ones. */
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
            val updatedAt = obj.optLong("updatedAt", 0L)
            if (now - updatedAt > EXPIRY_MS) {
                root.remove(key)
                changed = true
            } else {
                result[key] = Entry(
                    source = obj.optString("source"),
                    desiredCompleted = obj.optBoolean("desiredCompleted"),
                    revision = obj.optLong("revision"),
                )
            }
        }
        if (changed) {
            p.edit().putString(KEY_ENTRIES, root.toString()).apply()
        }
        return result
    }
}
