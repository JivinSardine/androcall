package dev.androcall.android.telephony

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Watches the phone's call state and reports it to the Mac.
 *
 * Two code paths are needed because Android replaced the telephony callback
 * API in API 31:
 *
 * * API 31+: `TelephonyCallback.CallStateListener`, which also delivers the
 *   incoming number.
 * * API 24–30: the deprecated `PhoneStateListener`, which delivers the state
 *   but not the number.
 */
class CallMonitor(
    private val context: Context,
    private val listener: Listener
) {

    interface Listener {
        /** The call state changed. `number` is only known on API 31+. */
        fun onCallStateChanged(state: Int, number: String?)

        /** The phone's own call state was read (a fallback for the listener). */
        fun onPoll(state: Int, number: String?)
    }

    private val executor: Executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "androcall-callmonitor").apply { isDaemon = true }
    }

    private var telephonyCallback: TelephonyCallback? = null
    private var phoneStateListener: PhoneStateListener? = null
    private var started = false

    /** Whether the app may observe the call state. */
    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED

    /** Start observing the call state. */
    fun start() {
        if (started || !hasPermission()) return
        started = true
        val manager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (manager == null) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // The public callback only carries the state; the caller number
                // is resolved from the call log by the service.
                val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        listener.onCallStateChanged(state, null)
                    }
                }
                telephonyCallback = callback
                manager.registerTelephonyCallback(executor, callback)
            } else {
                @Suppress("DEPRECATION")
                val phoneListener = object : PhoneStateListener() {
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        listener.onCallStateChanged(state, phoneNumber)
                    }
                }
                phoneStateListener = phoneListener
                manager.listen(phoneListener, PhoneStateListener.LISTEN_CALL_STATE)
            }
        } catch (error: SecurityException) {
            Log.w(TAG, "could not observe the call state", error)
        }
    }

    /** Stop observing the call state. */
    fun stop() {
        if (!started) return
        started = false
        val manager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephonyCallback?.let { manager?.unregisterTelephonyCallback(it) }
                telephonyCallback = null
            } else {
                @Suppress("DEPRECATION")
                phoneStateListener?.let { manager?.listen(it, PhoneStateListener.LISTEN_NONE) }
                phoneStateListener = null
            }
        } catch (error: Exception) {
            Log.w(TAG, "could not stop observing the call state", error)
        }
    }

    /** Read the current call state directly (used when the listener misses an event). */
    fun pollState(): Int {
        if (!hasPermission()) return TelephonyManager.CALL_STATE_IDLE
        val manager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return TelephonyManager.CALL_STATE_IDLE
        return try {
            @Suppress("DEPRECATION")
            manager.callState
        } catch (error: SecurityException) {
            TelephonyManager.CALL_STATE_IDLE
        }
    }

    /** Whether the phone can place calls at all. */
    fun hasTelephony(): Boolean = context.packageManager.hasSystemFeature(
        android.content.pm.PackageManager.FEATURE_TELEPHONY
    )

    companion object {
        private const val TAG = "AndroCallMonitor"
    }
}
