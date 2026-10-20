package dev.androcall.android.service

import android.util.Log
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * A small in-memory ring buffer of log lines.
 *
 * The companion can send this to the Mac on request so that a user can report
 * a problem without having to copy logs by hand. It never contains contact
 * data, call content or keys.
 */
object LogSnapshot {

    private const val TAG = "AndroCall"
    private const val MAXIMUM_LINES = 300
    private val lines = ArrayDeque<String>()
    private val formatter = SimpleDateFormat("HH:mm:ss", Locale.US)

    /** Record a line. */
    fun record(message: String) {
        val stamp = formatter.format(Date())
        synchronized(lines) {
            lines.addLast("[$stamp] $message")
            while (lines.size > MAXIMUM_LINES) {
                lines.removeFirst()
            }
        }
    }

    /** Record a line and write it to logcat. */
    fun record(priority: Int, message: String) {
        record(message)
        Log.println(priority, TAG, message)
    }

    /** The recorded lines, oldest first. */
    fun lines(): List<String> = synchronized(lines) { lines.toList() }

    /** Forget every line. */
    fun clear() {
        synchronized(lines) { lines.clear() }
    }
}
