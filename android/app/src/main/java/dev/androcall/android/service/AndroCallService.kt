package dev.androcall.android.service

import android.Manifest
import android.bluetooth.BluetoothManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import dev.androcall.android.MainActivity
import dev.androcall.android.R
import dev.androcall.android.ble.GattServer
import dev.androcall.android.protocol.CallState
import dev.androcall.android.protocol.CanonicalJson
import dev.androcall.android.protocol.Frame
import dev.androcall.android.protocol.JsonObjectBuilder
import dev.androcall.android.protocol.Message
import dev.androcall.android.protocol.Protocol
import dev.androcall.android.protocol.ServerSession
import dev.androcall.android.telephony.CallMonitor
import dev.androcall.android.telephony.ContactsRepository
import dev.androcall.android.telephony.TelephonyController
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The foreground service that hosts the GATT server.
 *
 * Android only keeps a GATT server reliably reachable while the app is in the
 * foreground, so the server runs inside a foreground service with a permanent
 * notification. The user can turn the notification off, but the service then
 * risks being killed by the system, which is explained in the app.
 */
class AndroCallService : Service() {

    private lateinit var gattServer: GattServer
    private lateinit var session: ServerSession
    private lateinit var contacts: ContactsRepository
    private lateinit var telephony: TelephonyController
    private lateinit var callMonitor: CallMonitor
    private val running = AtomicBoolean(false)

    /** The PIN the user entered; the session refuses to start without one. */
    @Volatile
    var pin: String = ""

    /** The connection state, mirrored into the notification. */
    @Volatile
    var connected: Boolean = false
        private set

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        contacts = ContactsRepository(this)
        telephony = TelephonyController(this)
        callMonitor = CallMonitor(this, object : CallMonitor.Listener {
            override fun onCallStateChanged(state: Int, number: String?) {
                publishCallState(state, number)
            }

            override fun onPoll(state: Int, number: String?) {
                publishCallState(state, number)
            }
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                startForegroundCompat()
                if (running.compareAndSet(false, true)) {
                    startServer()
                }
            }
        }
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val notification = buildNotification("Waiting for your Mac…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startServer() {
        session = ServerSession(
            requestHandler = ::handleRequest,
            eventSink = { message -> session.sendEvent(message) },
            frameSink = { frame ->
                if (!gattServer.sendEvent(frame)) {
                    gattServer.sendBulk(frame)
                }
            },
            maxPayload = { gattServer.maximumPayloadSize },
            pin = pin
        )

        gattServer = GattServer(
            context = this,
            frameSink = { data -> session.onFrame(data) },
            connectionListener = { isConnected ->
                connected = isConnected
                if (!isConnected) {
                    session.onDisconnected()
                }
                updateNotification()
            }
        )

        val started = gattServer.start()
        if (!started) {
            Log.w(TAG, "could not start the GATT server")
            stopEverything()
            return
        }
        callMonitor.start()
        updateNotification()
    }

    private fun stopEverything() {
        running.set(false)
        callMonitor.stop()
        gattServer.stop()
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stopEverything()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // MARK: - Requests

    private fun handleRequest(message: Message) {
        when (message.type) {
            "device.info" -> {
                val builder = JsonObjectBuilder()
                builder.put("deviceName", deviceName())
                builder.put("manufacturer", android.os.Build.MANUFACTURER)
                builder.put("model", android.os.Build.MODEL)
                builder.put("androidVersion", android.os.Build.VERSION.RELEASE)
                builder.put("sdkInt", android.os.Build.VERSION.SDK_INT)
                builder.putOrNull("batteryLevel", batteryLevel())
                builder.putOrNull("batteryCharging", batteryCharging())
                builder.putOrNull("signalStrength", signalStrength())
                builder.put("telephonyCapable", telephony.hasTelephony())
                session.sendEvent(Message("device.info", replyTo = message.id, body = builder.build().members))
            }

            "call.capabilities" -> {
                val capabilities = telephony.capabilities(audioRoute())
                val builder = JsonObjectBuilder()
                builder.put("canAnswer", capabilities.canAnswer)
                builder.put("canDecline", capabilities.canDecline)
                builder.put("canEnd", capabilities.canEnd)
                builder.put("canMute", capabilities.canMute)
                builder.put("canSelectAudioDevice", capabilities.canSelectAudioDevice)
                builder.putOrNull("audioRoute", capabilities.audioRoute)
                builder.put("defaultDialer", capabilities.isDefaultDialer)
                builder.putOrNull("reason", capabilities.reason)
                session.sendEvent(
                    Message("call.capabilities", replyTo = message.id, body = builder.build().members)
                )
            }

            "contacts.request" -> sendContacts(message)

            "contact.favorite.set" -> {
                val contactId = message.string("contactId") ?: ""
                val favorite = message.bool("favorite") ?: false
                val updated = contacts.setFavorite(contactId, favorite)
                val builder = JsonObjectBuilder()
                builder.put("contactId", contactId)
                builder.put("favorite", favorite)
                builder.put("updated", updated)
                builder.putOrNull("reason", if (updated) null else "The contact could not be updated.")
                session.sendEvent(
                    Message("contact.favorite.result", replyTo = message.id, body = builder.build().members)
                )
            }

            "call.place" -> {
                val requestId = message.string("requestId") ?: ""
                val number = message.string("number") ?: ""
                val error = telephony.placeCall(number)
                val builder = JsonObjectBuilder()
                builder.put("requestId", requestId)
                builder.put("callId", requestId)
                builder.put("accepted", error == null)
                builder.putOrNull("code", if (error == null) null else "rejected")
                builder.putOrNull("message", error)
                session.sendEvent(
                    Message("call.place.result", replyTo = message.id, body = builder.build().members)
                )
                if (error != null) {
                    Log.w(TAG, "could not place the call: $error")
                }
            }

            "call.answer" -> respondToCallAction(message, telephony.acceptCall())
            "call.decline" -> respondToCallAction(message, telephony.declineCall())
            "call.end" -> respondToCallAction(message, telephony.endCall())
            "call.mute" -> respondToCallAction(message, null)

            "log.request" -> {
                val builder = JsonObjectBuilder()
                builder.put("requestId", message.string("requestId") ?: "")
                builder.put(
                    "lines",
                    CanonicalJson.Value.Arr(
                        LogSnapshot.lines().map { CanonicalJson.Value.Str(it) }
                    )
                )
                session.sendEvent(Message("log.batch", replyTo = message.id, body = builder.build().members))
            }

            else -> {
                session.sendError("invalid_message", "Unknown request '${message.type}'.")
            }
        }
    }

    private fun respondToCallAction(message: Message, error: String?) {
        val builder = JsonObjectBuilder()
        builder.put("requestId", message.string("requestId") ?: "")
        builder.put("callId", message.string("callId") ?: "")
        builder.put("ok", error == null)
        builder.putOrNull("code", if (error == null) null else "not_default_dialer")
        builder.putOrNull("message", error)
        session.sendEvent(Message("call.result", replyTo = message.id, body = builder.build().members))
    }

    private fun sendContacts(message: Message) {
        val requestId = message.string("requestId") ?: ""
        if (!contacts.hasPermission()) {
            val builder = JsonObjectBuilder()
            builder.put("requestId", requestId)
            builder.put("code", "permission_denied")
            builder.put("message", "androcall has not been allowed to read your contacts.")
            session.sendEvent(Message("contacts.error", replyTo = message.id, body = builder.build().members))
            return
        }
        val all = contacts.readContacts()
        val batchSize = 25
        val batches = all.chunked(batchSize)
        if (batches.isEmpty()) {
            val builder = JsonObjectBuilder()
            builder.put("requestId", requestId)
            builder.put("index", 0)
            builder.put("total", 0)
            builder.put("contacts", CanonicalJson.Value.Arr(emptyList()))
            builder.put("hasMore", false)
            session.sendEvent(Message("contacts.batch", replyTo = message.id, body = builder.build().members))
            val complete = JsonObjectBuilder()
            complete.put("requestId", requestId)
            complete.put("total", 0)
            session.sendEvent(Message("contacts.complete", replyTo = message.id, body = complete.build().members))
            return
        }
        batches.forEachIndexed { index, batch ->
            val builder = JsonObjectBuilder()
            builder.put("requestId", requestId)
            builder.put("index", index)
            builder.put("total", batches.size)
            builder.put(
                "contacts",
                CanonicalJson.Value.Arr(
                    batch.map { contact ->
                        CanonicalJson.Value.Obj(
                            linkedMapOf<String, CanonicalJson.Value>().apply {
                                put("id", CanonicalJson.Value.Str(contact.id))
                                put("lookupKey", CanonicalJson.Value.Str(contact.lookupKey))
                                put("displayName", CanonicalJson.Value.Str(contact.displayName))
                                put("givenName", contact.givenName?.let { CanonicalJson.Value.Str(it) }
                                    ?: CanonicalJson.Value.Null)
                                put("familyName", contact.familyName?.let { CanonicalJson.Value.Str(it) }
                                    ?: CanonicalJson.Value.Null)
                                put("organization", contact.organization?.let { CanonicalJson.Value.Str(it) }
                                    ?: CanonicalJson.Value.Null)
                                put("phoneNumbers", CanonicalJson.Value.Arr(
                                    contact.phoneNumbers.map { number ->
                                        CanonicalJson.Value.Obj(
                                            linkedMapOf<String, CanonicalJson.Value>().apply {
                                                put("label", CanonicalJson.Value.Str(number.label))
                                                put("number", CanonicalJson.Value.Str(number.number))
                                                put("normalized", CanonicalJson.Value.Str(number.normalized))
                                                put("type", CanonicalJson.Value.Str(number.type))
                                            }
                                        )
                                    }
                                ))
                                put("emails", CanonicalJson.Value.Arr(
                                    contact.emails.map { email ->
                                        CanonicalJson.Value.Obj(
                                            linkedMapOf<String, CanonicalJson.Value>().apply {
                                                put("label", CanonicalJson.Value.Str(email.label))
                                                put("address", CanonicalJson.Value.Str(email.address))
                                            }
                                        )
                                    }
                                ))
                                put("photo", contact.photo?.let {
                                    CanonicalJson.Value.Str(
                                        android.util.Base64.encodeToString(
                                            it, android.util.Base64.NO_WRAP
                                        )
                                    )
                                } ?: CanonicalJson.Value.Null)
                                put("photoMimeType", contact.photoMimeType?.let {
                                    CanonicalJson.Value.Str(it)
                                } ?: CanonicalJson.Value.Null)
                                put("starred", CanonicalJson.Value.Bool(contact.starred))
                                put("sortKey", CanonicalJson.Value.Str(contact.sortKey))
                            }
                        )
                    }
                ))
                builder.put("hasMore", index != batches.size - 1)
                session.sendEvent(Message("contacts.batch", replyTo = message.id, body = builder.build().members))
        }
        val complete = JsonObjectBuilder()
        complete.put("requestId", requestId)
        complete.put("total", all.size)
        session.sendEvent(Message("contacts.complete", replyTo = message.id, body = complete.build().members))
    }

    // MARK: - Call events

    private fun publishCallState(state: Int, number: String?) {
        val callState = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> CallState.RINGING_INCOMING
            TelephonyManager.CALL_STATE_OFFHOOK -> CallState.ACTIVE
            TelephonyManager.CALL_STATE_IDLE -> CallState.ENDED
            else -> CallState.UNKNOWN
        }
        if (callState == CallState.UNKNOWN) return
        val builder = JsonObjectBuilder()
        builder.put("callId", currentCallId())
        builder.put("state", callState.wireValue)
        builder.putOrNull("number", number)
        builder.putOrNull("displayName", null as String?)
        builder.putOrNull("startedAt", null as Long?)
        builder.putOrNull("durationMs", null as Long?)
        session.sendEvent(Message("call.state", body = builder.build().members))
    }

    private fun currentCallId(): String = "call_${System.currentTimeMillis()}"

    // MARK: - Device information

    private fun deviceName(): String {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter?.name ?: android.os.Build.MODEL ?: "Android phone"
    }

    private fun batteryLevel(): Int? {
        val manager = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return null
        val level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (level in 0..100) level else null
    }

    private fun batteryCharging(): Boolean? {
        val intent = registerReceiver(null, android.content.IntentFilter(
            android.content.Intent.ACTION_BATTERY_CHANGED
        )) ?: return null
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun signalStrength(): Int? {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val manager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return null
        return try {
            // `SignalStrength.getLevel()` is a 0..4 bucket; the dBm value is the
            // deprecated GSM reading and is not available on every device.
            manager.signalStrength?.level
        } catch (error: Exception) {
            null
        }
    }

    private fun audioRoute(): String = "Phone earpiece"

    // MARK: - Notification

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        channel.description = getString(R.string.notification_channel_description)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        val text = if (connected) {
            getString(R.string.notification_connected)
        } else {
            getString(R.string.notification_waiting)
        }
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val TAG = "AndroCallService"
        private const val CHANNEL_ID = "androcall.connection"
        private const val NOTIFICATION_ID = 4201

        const val ACTION_START = "dev.androcall.action.START"
        const val ACTION_STOP = "dev.androcall.action.STOP"

        /** Start the service. */
        fun start(context: Context) {
            val intent = Intent(context, AndroCallService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Stop the service. */
        fun stop(context: Context) {
            val intent = Intent(context, AndroCallService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
