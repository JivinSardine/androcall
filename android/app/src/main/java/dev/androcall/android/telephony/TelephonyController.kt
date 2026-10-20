package dev.androcall.android.telephony

import android.Manifest
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.content.ContextCompat
import dev.androcall.android.protocol.CallCapabilities

/**
 * Places and controls calls.
 *
 * **Placing** a call needs nothing special: `TelecomManager.placeCall` works
 * for any app that holds `CALL_PHONE`.
 *
 * **Answering, rejecting and ending** a call needs the app to be the phone's
 * **default dialer**. Android does not allow any other app to do it. The
 * companion therefore reports exactly what it can do, and the Mac disables the
 * controls it cannot honour rather than pretending they work.
 */
class TelephonyController(private val context: Context) {

    /** Whether the app may place calls. */
    fun canPlaceCalls(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CALL_PHONE) ==
            PackageManager.PERMISSION_GRANTED

    /** Whether the phone is telephony capable at all. */
    fun hasTelephony(): Boolean = context.packageManager.hasSystemFeature(
        android.content.pm.PackageManager.FEATURE_TELEPHONY
    )

    /** Whether the companion is the phone's default dialer. */
    fun isDefaultDialer(): Boolean {
        val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            ?: return false
        return try {
            manager.defaultDialerPackage == context.packageName
        } catch (error: Exception) {
            false
        }
    }

    /**
     * Place a call.
     *
     * @return an error message, or null when the call was placed.
     */
    fun placeCall(number: String): String? {
        if (!hasTelephony()) return "This device cannot make phone calls."
        if (!canPlaceCalls()) {
            // Fall back to the dialer so the user can still place the call.
            return openDialer(number)
        }
        return try {
            val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return "The phone's telephony service is not available."
            manager.placeCall(Uri.parse("tel:$number"), null)
            null
        } catch (error: SecurityException) {
            Log.w(TAG, "could not place the call", error)
            "Android refused the call: ${error.message}"
        }
    }

    /** Open the system dialer with the number pre-filled. */
    private fun openDialer(number: String): String? {
        return try {
            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            null
        } catch (error: Exception) {
            "The call could not be placed."
        }
    }

    /** Accept a ringing call. Only the default dialer may do this. */
    fun acceptCall(): String? {
        if (!isDefaultDialer()) {
            return "androcall must be your phone's default dialer app to answer calls."
        }
        return try {
            val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return "The phone's telephony service is not available."
            manager.acceptRingingCall()
            null
        } catch (error: SecurityException) {
            "Android refused the request: ${error.message}"
        }
    }

    /** Reject a ringing call. */
    fun declineCall(): String? {
        if (!isDefaultDialer()) {
            return "androcall must be your phone's default dialer app to decline calls."
        }
        return try {
            val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return "The phone's telephony service is not available."
            manager.endCall()
            null
        } catch (error: SecurityException) {
            "Android refused the request: ${error.message}"
        }
    }

    /** End the call in progress. */
    fun endCall(): String? {
        if (!isDefaultDialer()) {
            return "androcall must be your phone's default dialer app to end calls."
        }
        return try {
            val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return "The phone's telephony service is not available."
            manager.endCall()
            null
        } catch (error: SecurityException) {
            "Android refused the request: ${error.message}"
        }
    }

    /** What the phone can actually do right now. */
    fun capabilities(audioRoute: String?): CallCapabilities {
        val defaultDialer = isDefaultDialer()
        val reason = if (defaultDialer) {
            null
        } else {
            "Answering, declining and ending calls needs androcall to be your phone's " +
                "default dialer app. You can set that in the phone's Settings."
        }
        return CallCapabilities(
            canAnswer = defaultDialer,
            canDecline = defaultDialer,
            canEnd = defaultDialer,
            canMute = defaultDialer,
            canSelectAudioDevice = defaultDialer,
            audioRoute = audioRoute,
            isDefaultDialer = defaultDialer,
            reason = reason
        )
    }

    /**
     * Build the intent that asks the user to make androcall the default
     * dialer app.
     */
    fun defaultDialerIntent(): Intent? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = context.getSystemService(Context.ROLE_SERVICE) as? RoleManager
            roleManager?.createRequestRoleIntent(RoleManager.ROLE_DIALER)
        } else {
            Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER)
                .putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, context.packageName)
        }
    }

    companion object {
        private const val TAG = "AndroCallTelephony"
    }
}
