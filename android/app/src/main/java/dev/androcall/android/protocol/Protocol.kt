package dev.androcall.android.protocol

/**
 * The androcall wire protocol, version 1.
 *
 * See `protocol/PROTOCOL.md` for the normative description.
 */
object Protocol {

    const val VERSION = 1

    /** Frame layer. */
    val MAGIC = byteArrayOf(0x41, 0x43)
    const val FRAME_VERSION = 0x01
    const val HEADER_SIZE = 23
    const val TAG_SIZE = 16

    const val KIND_PLAINTEXT = 0x01
    const val KIND_ENCRYPTED = 0x02

    const val FLAG_MORE = 0x01
    const val FLAG_FIRST = 0x02

    /** GCM nonce direction constants. */
    const val DIRECTION_CLIENT_TO_SERVER = 0x00000001
    const val DIRECTION_SERVER_TO_CLIENT = 0x00000002

    const val PBKDF2_ITERATIONS = 210_000

    const val MAX_FRAGMENTS_PER_MESSAGE = 64
    const val MAX_MESSAGE_BYTES = 1 shl 20

    const val REQUEST_TIMEOUT_SECONDS = 10L
    const val BULK_WINDOW = 8

    /** BLE GATT identifiers. */
    object Gatt {
        const val SERVICE = "A9D00001-1C3E-4B7A-9F21-6D2C5B8E4A10"
        const val CONTROL = "A9D00002-1C3E-4B7A-9F21-6D2C5B8E4A10"
        const val EVENT = "A9D00003-1C3E-4B7A-9F21-6D2C5B8E4A10"
        const val BULK = "A9D00004-1C3E-4B7A-9F21-6D2C5B8E4A10"
    }

    /** The capabilities a peer may advertise. */
    object Capability {
        const val CONTACTS = "contacts"
        const val RECENTS = "recents"
        const val CALL_PLACE = "call.place"
        const val CALL_STATE = "call.state"
        const val CALL_ANSWER = "call.answer"
        const val CALL_DECLINE = "call.decline"
        const val CALL_END = "call.end"
        const val CALL_MUTE = "call.mute"
        const val DEVICE_INFO = "device.info"
        const val FAVORITES = "contacts.favorite"

        /** Everything the phone can do. */
        val ALL: List<String> = listOf(
            CONTACTS, RECENTS, CALL_PLACE, CALL_STATE, CALL_ANSWER,
            CALL_DECLINE, CALL_END, CALL_MUTE, DEVICE_INFO, FAVORITES
        )
    }
}
