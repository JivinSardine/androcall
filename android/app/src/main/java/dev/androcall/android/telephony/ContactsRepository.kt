package dev.androcall.android.telephony

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.util.Base64
import androidx.core.content.ContextCompat
import dev.androcall.android.protocol.Contact
import dev.androcall.android.protocol.EmailAddress
import dev.androcall.android.protocol.PhoneNumber

/**
 * Reads the phone's contacts.
 *
 * Nothing leaves the phone except through the authenticated session with the
 * Mac that the user paired. The repository never writes to the contacts
 * provider; the only exception is the "favourite" flag, which Android stores
 * in the contact's own starred column.
 */
class ContactsRepository(private val context: Context) {

    /** Whether the app may read contacts. */
    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Read the phone's contacts.
     *
     * @param limit the maximum number of contacts to return, or 0 for all.
     * @param offset the number of contacts to skip.
     * @return the contacts, sorted by display name.
     */
    fun readContacts(limit: Int = 0, offset: Int = 0): List<Contact> {
        if (!hasPermission()) return emptyList()
        val contacts = ArrayList<Contact>()
        val projection = arrayOf(
            ContactsContract.Contacts._ID,
            ContactsContract.Contacts.LOOKUP_KEY,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
            ContactsContract.Contacts.STARRED
        )
        val sorted = "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} COLLATE NOCASE ASC"
        context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            projection,
            null,
            null,
            sorted
        )?.use { cursor ->
            var skipped = 0
            while (cursor.moveToNext() && (limit == 0 || contacts.size < limit)) {
                if (skipped < offset) {
                    skipped += 1
                    continue
                }
                val id = cursor.getLong(0)
                val lookupKey = cursor.getString(1) ?: ""
                val displayName = cursor.getString(2) ?: ""
                val starred = cursor.getInt(3) != 0
                contacts.add(
                    Contact(
                        id = "c_$id",
                        lookupKey = lookupKey,
                        displayName = displayName,
                        givenName = null,
                        familyName = null,
                        organization = null,
                        phoneNumbers = readPhoneNumbers(id),
                        emails = readEmails(id),
                        photo = readPhoto(id),
                        photoMimeType = if (readPhoto(id) != null) "image/jpeg" else null,
                        starred = starred,
                        sortKey = displayName
                    )
                )
            }
        }
        return contacts
    }

    private fun readPhoneNumbers(contactId: Long): List<PhoneNumber> {
        val numbers = ArrayList<PhoneNumber>()
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.NORMALIZED_NUMBER,
            ContactsContract.CommonDataKinds.Phone.TYPE,
            ContactsContract.CommonDataKinds.Phone.LABEL
        )
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(contactId.toString()),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val number = cursor.getString(0) ?: continue
                val normalized = cursor.getString(1) ?: number
                val type = cursor.getInt(2)
                val label = cursor.getString(3) ?: typeName(type)
                numbers.add(
                    PhoneNumber(
                        label = label,
                        number = number,
                        normalized = normalized,
                        type = typeName(type)
                    )
                )
            }
        }
        return numbers
    }

    private fun readEmails(contactId: Long): List<EmailAddress> {
        val emails = ArrayList<EmailAddress>()
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Email.ADDRESS,
            ContactsContract.CommonDataKinds.Email.TYPE,
            ContactsContract.CommonDataKinds.Email.LABEL
        )
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            projection,
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
            arrayOf(contactId.toString()),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val address = cursor.getString(0) ?: continue
                val type = cursor.getInt(1)
                emails.add(EmailAddress(cursor.getString(2) ?: typeName(type), address))
            }
        }
        return emails
    }

    private fun readPhoto(contactId: Long): ByteArray? {
        val uri = Uri.withAppendedPath(
            ContactsContract.Contacts.CONTENT_URI,
            "$contactId/photo"
        )
        return try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = stream.read(buffer, total, buffer.size - total)
                    if (read <= 0) break
                    total += read
                    if (total >= buffer.size) break
                }
                if (total > 0) buffer.copyOf(total) else null
            }
        } catch (error: Exception) {
            null
        }
    }

    /** Set (or clear) the starred flag of a contact. */
    fun setFavorite(contactId: String, favorite: Boolean): Boolean {
        if (!hasPermission()) return false
        val numericId = contactId.removePrefix("c_").toLongOrNull() ?: return false
        val uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_URI, numericId.toString())
        val values = android.content.ContentValues().apply {
            put(ContactsContract.Contacts.STARRED, if (favorite) 1 else 0)
        }
        return try {
            context.contentResolver.update(uri, values, null, null) > 0
        } catch (error: Exception) {
            false
        }
    }

    private fun typeName(type: Int): String = when (type) {
        ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE -> "mobile"
        ContactsContract.CommonDataKinds.Phone.TYPE_HOME -> "home"
        ContactsContract.CommonDataKinds.Phone.TYPE_WORK -> "work"
        ContactsContract.CommonDataKinds.Phone.TYPE_MAIN -> "main"
        ContactsContract.CommonDataKinds.Phone.TYPE_OTHER -> "other"
        else -> "other"
    }

    /** Whether the phone can place calls at all. */
    fun hasTelephony(): Boolean {
        val manager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        return manager != null && context.packageManager.hasSystemFeature(
            android.content.pm.PackageManager.FEATURE_TELEPHONY
        )
    }
}
