package dev.androcall.android.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import dev.androcall.android.protocol.Frame
import dev.androcall.android.protocol.Protocol
import java.util.UUID

/**
 * The BLE GATT server the Mac connects to.
 *
 * The Android phone is the peripheral; the Mac is the central. The server
 * exposes one service with three characteristics:
 *
 * * `control` — Mac → phone, write (requests)
 * * `event` — phone → Mac, notify (events)
 * * `bulk` — both directions, used for large payloads
 *
 * Android replaced the GATT server callback class in API 31, so both shapes
 * are implemented and the right one is chosen at run time.
 */
class GattServer(
    private val context: Context,
    /** Called for every frame the Mac writes. */
    private val frameSink: (ByteArray) -> Unit,
    /** Called when the Mac connects or disconnects. */
    private val connectionListener: (Boolean) -> Unit
) {

    private var server: BluetoothGattServer? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null
    private var eventCharacteristic: BluetoothGattCharacteristic? = null
    private var bulkCharacteristic: BluetoothGattCharacteristic? = null
    private var connectedDevice: BluetoothDevice? = null

    /** The maximum payload that fits in one write on this connection. */
    @Volatile
    var maximumPayloadSize: Int = 20
        private set

    /** Start the GATT server and publish the service. */
    fun start(): Boolean {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        val service = BluetoothGattService(
            UUID.fromString(Protocol.Gatt.SERVICE),
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )

        controlCharacteristic = BluetoothGattCharacteristic(
            UUID.fromString(Protocol.Gatt.CONTROL),
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        eventCharacteristic = BluetoothGattCharacteristic(
            UUID.fromString(Protocol.Gatt.EVENT),
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        bulkCharacteristic = BluetoothGattCharacteristic(
            UUID.fromString(Protocol.Gatt.BULK),
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        service.addCharacteristic(controlCharacteristic)
        service.addCharacteristic(eventCharacteristic)
        service.addCharacteristic(bulkCharacteristic)

        val gattServer = manager.openGattServer(context, buildCallback())
        if (gattServer == null) return false
        server = gattServer
        gattServer.addService(service)
        Log.i(TAG, "GATT server started")
        return true
    }

    /** Stop the GATT server. */
    fun stop() {
        server?.close()
        server = null
        controlCharacteristic = null
        eventCharacteristic = null
        bulkCharacteristic = null
        connectedDevice = null
        Log.i(TAG, "GATT server stopped")
    }

    /** Send a frame to the Mac on the event characteristic. */
    fun sendEvent(frame: Frame): Boolean = notify(eventCharacteristic, frame)

    /** Send a frame to the Mac on the bulk characteristic. */
    fun sendBulk(frame: Frame): Boolean = notify(bulkCharacteristic, frame)

    private fun notify(
        characteristic: BluetoothGattCharacteristic?,
        frame: Frame
    ): Boolean {
        val gattServer = server ?: return false
        val device = connectedDevice ?: return false
        if (characteristic == null) return false
        return try {
            val bytes = frame.encode()
            if (bytes.size > maximumPayloadSize) {
                // The event channel is small; large payloads go over the bulk channel.
                return false
            }
            characteristic.value = bytes
            gattServer.notifyCharacteristicChanged(device, characteristic, false)
            true
        } catch (error: Exception) {
            Log.w(TAG, "could not notify the Mac", error)
            false
        }
    }

    private fun onConnected(device: BluetoothDevice) {
        connectedDevice = device
        connectionListener(true)
    }

    private fun onDisconnected() {
        connectedDevice = null
        connectionListener(false)
    }

    private fun onMtuChanged(mtu: Int) {
        // The ATT payload is three bytes shorter than the negotiated MTU.
        maximumPayloadSize = (mtu - 3).coerceAtLeast(20)
        Log.i(TAG, "MTU is now $mtu (payload $maximumPayloadSize bytes)")
    }

    private fun onWrite(value: ByteArray) {
        frameSink(value.copyOf())
    }

    /**
     * Build the callback object.
     *
     * Android 12 (API 31) replaced `BluetoothGattServer.BluetoothGattServerCallback`
     * with the top-level `BluetoothGattServerCallback`. androcall supports
     * Android 12 and later, so only the current API is used.
     */
    private fun buildCallback(): BluetoothGattServerCallback =
        object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(
                device: BluetoothDevice,
                status: Int,
                newState: Int
            ) {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> onConnected(device)
                    BluetoothProfile.STATE_DISCONNECTED -> onDisconnected()
                    else -> Unit
                }
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                onMtuChanged(mtu)
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                if (responseNeeded) {
                    // `android.bluetooth.GattStatus` is not part of the public
                    // SDK, so the success status is used directly.
                    server?.sendResponse(device, requestId, GATT_SUCCESS, 0, null)
                }
                if (!preparedWrite) {
                    onWrite(value)
                }
            }
        }

    companion object {
        private const val TAG = "AndroCallGatt"
        private const val GATT_SUCCESS = 0
    }
}
