package dev.androcall.android.protocol

import android.util.Base64
import org.json.JSONObject

/** One phone number of a contact. */
data class PhoneNumber(
    val label: String,
    val number: String,
    val normalized: String,
    val type: String
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("label", label)
        put("number", number)
        put("normalized", normalized)
        put("type", type)
    }
}

/** One email address of a contact. */
data class EmailAddress(val label: String, val address: String)

/** A phone contact synchronised to the Mac. */
data class Contact(
    val id: String,
    val lookupKey: String,
    val displayName: String,
    val givenName: String?,
    val familyName: String?,
    val organization: String?,
    val phoneNumbers: List<PhoneNumber>,
    val emails: List<EmailAddress>,
    val photo: ByteArray?,
    val photoMimeType: String?,
    val starred: Boolean,
    val sortKey: String
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("lookupKey", lookupKey)
        put("displayName", displayName)
        put("givenName", givenName ?: JSONObject.NULL)
        put("familyName", familyName ?: JSONObject.NULL)
        put("organization", organization ?: JSONObject.NULL)
        put("phoneNumbers", org.json.JSONArray().apply {
            phoneNumbers.forEach { put(it.toJson()) }
        })
        put("emails", org.json.JSONArray().apply {
            emails.forEach { put(JSONObject().apply {
                put("label", it.label)
                put("address", it.address)
            }) }
        })
        put("photo", photo?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: JSONObject.NULL)
        put("photoMimeType", photoMimeType ?: JSONObject.NULL)
        put("starred", starred)
        put("sortKey", sortKey)
    }
}

/** The state of a call. */
enum class CallState(val wireValue: String, val displayName: String) {
    DIALING("dialing", "Calling"),
    RINGING_OUTGOING("ringing_outgoing", "Ringing"),
    RINGING_INCOMING("ringing_incoming", "Incoming call"),
    ACTIVE("active", "Connected"),
    ENDING("ending", "Ending"),
    ENDED("ended", "Ended"),
    FAILED("failed", "Failed"),
    REJECTED("rejected", "Declined"),
    MISSED("missed", "Missed"),
    UNKNOWN("unknown", "Unknown");

    val isTerminal: Boolean
        get() = this == ENDED || this == FAILED || this == REJECTED || this == MISSED

    companion object {
        fun fromWire(value: String?): CallState =
            entries.firstOrNull { it.wireValue == value } ?: UNKNOWN
    }
}

/** A recent call entry. */
data class RecentCall(
    val id: String,
    val number: String,
    val displayName: String?,
    val type: String,
    val timestamp: Long,
    val durationMs: Long?
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("number", number)
        put("displayName", displayName ?: JSONObject.NULL)
        put("type", type)
        put("timestamp", timestamp)
        put("durationMs", durationMs ?: JSONObject.NULL)
    }
}

/** Information about the phone. */
data class DeviceInfo(
    val deviceName: String,
    val manufacturer: String,
    val model: String,
    val androidVersion: String,
    val sdkInt: Int,
    val batteryLevel: Int?,
    val batteryCharging: Boolean?,
    val signalStrength: Int?,
    val telephonyCapable: Boolean
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("deviceName", deviceName)
        put("manufacturer", manufacturer)
        put("model", model)
        put("androidVersion", androidVersion)
        put("sdkInt", sdkInt)
        put("batteryLevel", batteryLevel ?: JSONObject.NULL)
        put("batteryCharging", batteryCharging ?: JSONObject.NULL)
        put("signalStrength", signalStrength ?: JSONObject.NULL)
        put("telephonyCapable", telephonyCapable)
    }
}

/** The call-control capabilities the phone reports. */
data class CallCapabilities(
    val canAnswer: Boolean,
    val canDecline: Boolean,
    val canEnd: Boolean,
    val canMute: Boolean,
    val canSelectAudioDevice: Boolean,
    val audioRoute: String?,
    val isDefaultDialer: Boolean,
    val reason: String?
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("canAnswer", canAnswer)
        put("canDecline", canDecline)
        put("canEnd", canEnd)
        put("canMute", canMute)
        put("canSelectAudioDevice", canSelectAudioDevice)
        put("audioRoute", audioRoute ?: JSONObject.NULL)
        put("defaultDialer", isDefaultDialer)
        put("reason", reason ?: JSONObject.NULL)
    }
}

/**
 * Dial-pad input handling and phone-number sanitisation (PROTOCOL.md §5).
 *
 * The phone is authoritative for normalisation; the Mac only sanitises what the
 * user typed.
 */
object PhoneNumberSanitizer {

    private val ALLOWED = setOf('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#', '+', ',', ';')

    /** Strip the characters that humans add for readability. */
    fun sanitize(input: String): String {
        val builder = StringBuilder(input.length)
        for (character in input) {
            if (character.isWhitespace() || character == '-' || character == '(' ||
                character == ')' || character == '.' || character == '\u00A0' ||
                character == '\u202F'
            ) {
                continue
            }
            builder.append(character)
        }
        val cleaned = builder.toString()
        return if (cleaned.startsWith("00")) "+" + cleaned.substring(2) else cleaned
    }

    /** Whether the sanitised number is plausibly dialable. */
    fun isDialable(input: String): Boolean {
        val sanitized = sanitize(input)
        if (sanitized.isEmpty()) return false
        var digits = 0
        for (character in sanitized) {
            if (character.isDigit()) {
                digits += 1
            } else if (character !in "*#+;,") {
                return false
            }
        }
        return digits > 0
    }

    /** Filter a dial-pad string to the characters the pad allows. */
    fun filterDialPad(input: String): String = input.filter { it in ALLOWED }
}
