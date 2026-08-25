package dev.touchbridge.android.ui.screens

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import dev.touchbridge.android.Constants
import dev.touchbridge.android.core.BLEClient
import dev.touchbridge.android.core.ChallengeData
import dev.touchbridge.android.core.ChallengeHandler
import dev.touchbridge.android.core.KeystoreManager
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class ActivityLogItem(
    val id: String,
    val title: String,
    val detail: String,
    val timestamp: Long,
    val success: Boolean
)

data class TouchBridgeUiState(
    val isPaired: Boolean = false,
    val isConnected: Boolean = false,
    val isScanning: Boolean = false,
    val statusMessage: String = "Not connected",
    val challengeCount: Int = 0,
    val lastChallenge: String? = null,
    val pairedMacName: String? = null,
    val discoveredDevices: List<String> = emptyList(),
    val activityLog: List<ActivityLogItem> = emptyList(),
)

class TouchBridgeViewModel(private val context: Context) : ViewModel(), BLEClient.Listener {

    private val _uiState = MutableStateFlow(TouchBridgeUiState())
    val uiState: StateFlow<TouchBridgeUiState> = _uiState.asStateFlow()

    private val _authRequest = MutableSharedFlow<ChallengeData>()
    val authRequest: SharedFlow<ChallengeData> = _authRequest.asSharedFlow()

    val keystoreManager = KeystoreManager()
    val bleClient = BLEClient(context)
    val challengeHandler = ChallengeHandler(keystoreManager, bleClient)

    init {
        bleClient.listener = this

        // Check if already paired
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        val macId = prefs.getString(Constants.PREF_PAIRED_MAC_ID, null)
        val macName = prefs.getString(Constants.PREF_PAIRED_MAC_NAME, null)

        _uiState.value = _uiState.value.copy(
            isPaired = macId != null,
            pairedMacName = macName
        )
    }

    fun startScanning() {
        try {
            val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager
            if (bluetoothManager?.adapter?.isEnabled != true) {
                _uiState.value = _uiState.value.copy(
                    isScanning = false,
                    statusMessage = "Bluetooth is turned off"
                )
                return
            }

            val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
            val macId = prefs.getString(Constants.PREF_PAIRED_MAC_ID, null)
            val serviceUuid = macId?.let { 
                try { java.util.UUID.fromString(it) } catch (e: Exception) { null }
            }

            bleClient.startScanning(serviceUuid)
            _uiState.value = _uiState.value.copy(
                isScanning = true, 
                statusMessage = "Scanning...",
                discoveredDevices = emptyList()
            )
        } catch (e: SecurityException) {
            _uiState.value = _uiState.value.copy(
                isScanning = false,
                statusMessage = "Bluetooth permissions required"
            )
        }
    }

    fun connectTo(address: String) {
        bleClient.connect(address)
        _uiState.value = _uiState.value.copy(statusMessage = "Connecting...")
    }

    fun completePairing(macName: String, macId: String, pairingToken: ByteArray? = null) {
        android.util.Log.i("TouchBridgeVM", "Completing pairing for: $macName ($macId)")
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putString(Constants.PREF_PAIRED_MAC_ID, macId)
            .putString(Constants.PREF_PAIRED_MAC_NAME, macName)
            .apply()

        // Generate signing key if not present
        if (!keystoreManager.hasKey(Constants.SIGNING_KEY_ALIAS)) {
            keystoreManager.generateKeyPair(Constants.SIGNING_KEY_ALIAS)
        }

        // Generate a stable device ID for this Android device if not already set
        val deviceID = getOrCreateDeviceID()

        // Send pair request to daemon via BLE (with pairing token from QR)
        val publicKey = try {
            keystoreManager.getPublicKey(Constants.SIGNING_KEY_ALIAS)
        } catch (e: Exception) { null }
        if (publicKey != null) {
            val pairRequest = dev.touchbridge.android.core.WireFormat.buildPairRequest(
                deviceName = android.os.Build.MODEL,
                publicKey = publicKey,
                deviceID = deviceID,
                pairingToken = pairingToken ?: ByteArray(0)
            )
            bleClient.sendPairingData(pairRequest)
            Log.i("TouchBridgeVM", "Sent pair request with token=${pairingToken != null}")
        }

        _uiState.value = _uiState.value.copy(
            isPaired = true,
            pairedMacName = macName,
            statusMessage = "Paired with $macName"
        )

        // Immediately start scanning with the new ID
        startScanning()
    }

    /**
     * Get the stored device ID, or null if not yet paired.
     */
    private fun getDeviceID(): String? {
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(Constants.PREF_DEVICE_ID, null)
    }

    /**
     * Get or create a stable device ID for this Android device.
     * Used in pair requests and identify messages.
     */
    private fun getOrCreateDeviceID(): String {
        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        var deviceID = prefs.getString(Constants.PREF_DEVICE_ID, null)
        if (deviceID == null) {
            deviceID = java.util.UUID.randomUUID().toString()
            prefs.edit().putString(Constants.PREF_DEVICE_ID, deviceID).apply()
        }
        return deviceID
    }

    fun unpair() {
        bleClient.stopScanning()
        bleClient.disconnect()
        keystoreManager.deleteKey(Constants.SIGNING_KEY_ALIAS)

        val prefs = context.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().clear().apply()

        _uiState.value = TouchBridgeUiState()
    }

    fun sendAuthResponse(challengeID: String, signature: ByteArray) {
        val deviceID = android.os.Build.MODEL
        try {
            // Build the response payload, encrypt it, then frame with wire format header
            val responsePayload = challengeHandler.buildResponsePayload(challengeID, signature, deviceID)
            val encryptedResponse = challengeHandler.encrypt(responsePayload)

            if (bleClient.sendResponse(encryptedResponse)) {
                _uiState.value = _uiState.value.copy(
                    challengeCount = _uiState.value.challengeCount + 1,
                    statusMessage = "Authenticated successfully",
                    activityLog = _uiState.value.activityLog + ActivityLogItem(
                        id = challengeID,
                        title = "Authenticated on ${_uiState.value.pairedMacName ?: "Mac"}",
                        detail = "Successful biometric verification",
                        timestamp = System.currentTimeMillis(),
                        success = true
                    )
                )
            } else {
                _uiState.value = _uiState.value.copy(statusMessage = "Failed to send response")
            }
        } catch (e: Exception) {
            Log.e("TouchBridgeVM", "Error sending auth response", e)
            _uiState.value = _uiState.value.copy(statusMessage = "Encryption error")
        }
    }

    /**
     * Send an error message to the daemon (e.g. key invalidated).
     */
    fun sendError(code: Int, description: String, challengeID: String? = null) {
        try {
            bleClient.sendError(code, description, challengeID)
        } catch (e: Exception) {
            Log.e("TouchBridgeVM", "Failed to send error to daemon", e)
        }
    }

    // MARK: - BLEClient.Listener

    override fun onConnectionChanged(connected: Boolean, deviceAddress: String) {
        _uiState.value = _uiState.value.copy(
            isConnected = connected,
            isScanning = !connected && _uiState.value.isPaired,
            statusMessage = if (connected) "Connected to Mac" else "Disconnected"
        )

        if (connected) {
            // Initiate ECDH key exchange
            val publicKey = challengeHandler.initiateECDH()
            bleClient.sendSessionKey(publicKey)
        } else {
            // Disconnected - restart scanning if paired
            if (_uiState.value.isPaired) {
                startScanning()
            }
        }
    }

    override fun onChallengeReceived(data: ByteArray, deviceAddress: String) {
        try {
            val decrypted = challengeHandler.decrypt(data)
            val challenge = challengeHandler.parseChallenge(decrypted)
            
            viewModelScope.launch {
                _authRequest.emit(challenge)
            }
            
            _uiState.value = _uiState.value.copy(
                lastChallenge = challenge.reason,
                statusMessage = "Auth request: ${challenge.reason}"
            )
        } catch (e: Exception) {
            Log.e("TouchBridgeVM", "Failed to process challenge", e)
        }
    }

    override fun onSessionKeyReceived(data: ByteArray, deviceAddress: String) {
        challengeHandler.completeECDH(data)
        _uiState.value = _uiState.value.copy(
            statusMessage = "Connected — session encrypted"
        )

        // After ECDH, send identify so the daemon recognizes this device
        // without requiring full re-pairing on reconnect.
        val deviceID = getDeviceID()
        val deviceName = android.os.Build.MODEL
        if (deviceID != null) {
            bleClient.sendIdentify(deviceID, deviceName)
            Log.i("TouchBridgeVM", "Sent identify: $deviceID ($deviceName)")
        }
    }

    override fun onDeviceDiscovered(deviceAddress: String) {
        if (uiState.value.isPaired && !uiState.value.isConnected && uiState.value.statusMessage != "Connecting...") {
            android.util.Log.i("TouchBridgeVM", "Auto-connecting to discovered device: $deviceAddress")
            connectTo(deviceAddress)
        }

        _uiState.value = _uiState.value.copy(
            discoveredDevices = bleClient.discoveredDeviceAddresses
        )
    }

    override fun onPairingDataReceived(data: ByteArray, deviceAddress: String) {
        // Parse pairing response from Mac (protobuf)
        try {
            // Strip wire format header [version][type] before parsing
            val payload = if (data.size > 2) data.copyOfRange(2, data.size) else data
            val response = dev.touchbridge.android.proto.PairResponse.parseFrom(payload)
            if (response.accepted) {
                val macId = response.deviceId.ifEmpty { deviceAddress }
                completePairing("Mac", macId)
            }
        } catch (e: Exception) {
            _uiState.value = _uiState.value.copy(statusMessage = "Pairing failed")
        }
    }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return TouchBridgeViewModel(context) as T
        }
    }
}
