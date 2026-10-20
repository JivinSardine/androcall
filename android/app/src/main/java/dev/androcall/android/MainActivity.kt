package dev.androcall.android

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.InputFilter
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import dev.androcall.android.service.AndroCallService
import dev.androcall.android.telephony.TelephonyController

/**
 * The companion app's single screen.
 *
 * It explains what the app does, asks for the permissions it needs (one at a
 * time, with a reason), takes the pairing PIN the user types, and shows the
 * verification code that must match the Mac.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var codeText: TextView
    private lateinit var pinField: EditText
    private lateinit var startButton: Button
    private lateinit var permissionsGroup: LinearLayout
    private lateinit var defaultDialerButton: Button

    private val telephony by lazy { TelephonyController(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.status)
        codeText = findViewById(R.id.code)
        pinField = findViewById(R.id.pin)
        startButton = findViewById(R.id.start)
        permissionsGroup = findViewById(R.id.permissions)
        defaultDialerButton = findViewById(R.id.default_dialer)

        pinField.filters = arrayOf(InputFilter.LengthFilter(6))
        startButton.setOnClickListener { onStartClicked() }
        defaultDialerButton.setOnClickListener { onDefaultDialerClicked() }

        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        val bluetoothOn = isBluetoothOn()
        val missing = missingPermissions()

        statusText.text = when {
            !bluetoothOn -> getString(R.string.status_bluetooth_off)
            missing.isNotEmpty() -> getString(
                R.string.status_needs_permissions,
                missing.joinToString(", ") { permissionLabel(it) }
            )
            else -> getString(R.string.status_ready)
        }

        permissionsGroup.visibility = if (missing.isEmpty()) View.GONE else View.VISIBLE
        for (permission in missing) {
            val button = permissionButton(permission)
            if (button.parent == null) {
                permissionsGroup.addView(button)
            }
        }

        val needsDialer = !telephony.isDefaultDialer() && telephony.hasTelephony()
        defaultDialerButton.visibility = if (needsDialer) View.VISIBLE else View.GONE
    }

    private fun permissionButton(permission: String): Button {
        val button = Button(this)
        button.text = getString(R.string.grant_permission, permissionLabel(permission))
        button.setOnClickListener { requestPermissions(arrayOf(permission), REQUEST_PERMISSION) }
        return button
    }

    private fun permissionLabel(permission: String): String = when (permission) {
        Manifest.permission.BLUETOOTH_CONNECT -> getString(R.string.permission_bluetooth)
        Manifest.permission.BLUETOOTH_SCAN -> getString(R.string.permission_bluetooth_scan)
        Manifest.permission.READ_CONTACTS -> getString(R.string.permission_contacts)
        Manifest.permission.READ_PHONE_STATE -> getString(R.string.permission_phone_state)
        Manifest.permission.CALL_PHONE -> getString(R.string.permission_call)
        else -> permission.substringAfterLast('.')
    }

    private fun missingPermissions(): List<String> {
        val permissions = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        permissions.add(Manifest.permission.READ_CONTACTS)
        permissions.add(Manifest.permission.READ_PHONE_STATE)
        permissions.add(Manifest.permission.CALL_PHONE)
        return permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun isBluetoothOn(): Boolean {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter?.isEnabled == true
    }

    private fun onStartClicked() {
        val pin = pinField.text.toString()
        if (pin.length != 6 || !pin.all { it.isDigit() }) {
            Toast.makeText(this, R.string.pin_required, Toast.LENGTH_SHORT).show()
            return
        }
        if (!isBluetoothOn()) {
            Toast.makeText(this, R.string.bluetooth_required, Toast.LENGTH_LONG).show()
            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
            return
        }
        AndroCallService.start(this)
        codeText.text = getString(R.string.code_waiting)
        Toast.makeText(this, R.string.service_started, Toast.LENGTH_SHORT).show()
    }

    private fun onDefaultDialerClicked() {
        val intent = telephony.defaultDialerIntent()
        if (intent != null) {
            startActivity(intent)
        } else {
            Toast.makeText(this, R.string.default_dialer_unavailable, Toast.LENGTH_LONG).show()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    companion object {
        private const val REQUEST_PERMISSION = 1001
    }
}
