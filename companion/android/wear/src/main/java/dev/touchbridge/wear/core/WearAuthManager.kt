package dev.touchbridge.wear.core

import android.content.Context
import android.util.Log
import dev.touchbridge.core.BLEClient
import dev.touchbridge.core.ChallengeData
import dev.touchbridge.core.ChallengeHandler
import dev.touchbridge.core.Constants
import dev.touchbridge.core.KeystoreManager
import dev.touchbridge.core.WireFormat
import dev.touchbridge.core.proto.DeviceCapabilities
import dev.touchbridge.core.proto.DeviceType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Orchestrates the full TouchBridge auth flow on Wear OS.
 *
 * The watch pairs directly with the Mac, establishes its own ECDH session,
 * sends a signed Identify, and signs challenge responses with its own
 * Keystore key. No phone relay required for the primary auth path.
 *
 * Biometric gate is configurable:
 * - SECURE: requires watch unlock (PIN/pattern) before signing.
 * - QUICK: just an Approve button tap, no unlock check.
 */
class WearAuthManager(private val context: Context) {

    companion object {
        private const val TAG = "WearAuthManager"
        private const val PREFS_NAME = "touchbridge_wear_prefs"
        private const val KEY_MAC_ID = "paired_mac_id"
        private const val KEY_MAC_NAME = "paired_mac_name"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_BIOMETRIC_MODE = "biometric_mode"
        private const val SIGNING_KEY_ALIAS = "dev.touchbridge.wear.signing"
    }

    enum class ConnectionState {
        DISCONNECTED, SCANNING, CONNECTING, CONNECTED, IDENTIFIED, FAILED
    }

    enum class BiometricMode {
        SECURE,  // requires watch unlock before signing
        QUICK    // just tap Approve, no unlock check
    }

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState

    private val _pendingChallenge = MutableStateFlow<ChallengeData?>(null)
    val pendingChallenge: StateFlow<ChallengeData?> = _pendingChallenge

    private val _paired = MutableStateFlow(false)
    val paired: StateFlow<Boolean> = _paired

    var biometricMode: BiometricMode = BiometricMode.SECURE
        private set

    private val keystoreManager = KeystoreManager()
    private val challengeHandler = ChallengeHandler(keystoreManager)
    private var bleClient: BLEClient? = null

    private var deviceID: String = ""
    private var deviceName: String = android.os.Build.MODEL
    private var macDeviceID: String? = null

    // Pairing state
    private var pairingToken: ByteArray? = null

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    init {
        loadPairedState()
    }

    private fun loadPairedState() {
        macDeviceID = prefs.getString(KEY_MAC_ID, null)
        deviceID = prefs.getString(KEY_DEVICE_ID, "") ?: ""
        biometricMode = BiometricMode.valueOf(
            prefs.getString(KEY_BIOMETRIC_MODE, BiometricMode.SECURE.name) ?: BiometricMode.SECURE.name
        )
        _paired.value = macDeviceID != null && keystoreManager.hasKey(SIGNING_KEY_ALIAS)
    }

    fun setBiometricMode(mode: BiometricMode) {
        biometricMode = mode
        prefs.edit().putString(KEY_BIOMETRIC_MODE, mode.name).apply()
    }

    /**
     * Generate a new key pair for pairing.
     * Returns the public key in X9.62 uncompressed format (65 bytes).
     */
    fun generateKeyForPairing(): ByteArray {
        return keystoreManager.generateKeyPair(SIGNING_KEY_ALIAS)
    }

    /**
     * Start pairing with a Mac.
     * @param macDeviceID the Mac's device ID from the QR code
     * @param pairingToken the pairing token from the QR code
     * @param macName the Mac's name (for display)
     */
    fun startPairing(macDeviceID: String, pairingToken: ByteArray, macName: String) {
        this.macDeviceID = macDeviceID
        this.pairingToken = pairingToken
        this.deviceID = java.util.UUID.randomUUID().toString()

        _connectionState.value = ConnectionState.SCANNING
        ensureBLEClient()
        bleClient?.startScanning(Constants.SERVICE_UUID)
    }

    /**
     * Connect to the Mac for auth (after pairing is already done).
     */
    fun connectForAuth() {
        if (macDeviceID == null) {
            Log.w(TAG, "Cannot connect — not paired")
            return
        }
        _connectionState.value = ConnectionState.SCANNING
        ensureBLEClient()
        bleClient?.startScanning(Constants.SERVICE_UUID)
    }

    private fun ensureBLEClient() {
        if (bleClient == null) {
            bleClient = BLEClient(context)
            bleClient?.listener = bleListener
        }
    }

    /**
     * Disconnect and stop scanning.
     */
    fun disconnect() {
        bleClient?.disconnect()
        bleClient?.stopScanning()
        _connectionState.value = ConnectionState.DISCONNECTED
    }

    /**
     * Unpair — delete key and clear prefs.
     */
    fun unpair() {
        keystoreManager.deleteKey(SIGNING_KEY_ALIAS)
        prefs.edit()
            .remove(KEY_MAC_ID)
            .remove(KEY_MAC_NAME)
            .remove(KEY_DEVICE_ID)
            .apply()
        macDeviceID = null
        deviceID = ""
        _paired.value = false
        disconnect()
    }

    /**
     * Sign a challenge nonce after user approval.
     * Called from the UI after the user taps Approve.
     */
    fun signChallenge(challengeData: ChallengeData): ByteArray? {
        return try {
            val nonce = challengeHandler.decrypt(challengeData.encryptedNonce)
            keystoreManager.sign(nonce, SIGNING_KEY_ALIAS)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sign challenge", e)
            null
        }
    }

    /**
     * Send the signed challenge response back to the Mac.
     */
    fun sendChallengeResponse(challengeID: String, signature: ByteArray) {
        val responsePayload = challengeHandler.buildResponsePayload(challengeID, signature, deviceID)
        bleClient?.sendResponse(responsePayload)
        _pendingChallenge.value = null
    }

    /**
     * Send an error message to the Mac.
     */
    fun sendError(code: Int, description: String, challengeID: String? = null) {
        bleClient?.sendError(code, description, challengeID)
    }

    /**
     * Build the device capabilities for a watch.
     */
    private fun watchCaps(): DeviceCapabilities {
        val hasStrongBox = try {
            context.packageManager.hasSystemFeature("android.hardware.strongbox_keystore")
        } catch (e: Exception) {
            false
        }

        return DeviceCapabilities.newBuilder()
            .setHasBiometric(false)
            .setHasSecureEnclave(hasStrongBox)
            .setHasDisplay(true)
            .setHasButton(true)
            .setLatencyClass(1)
            .build()
    }

    /**
     * Build a pair request for the Mac.
     */
    fun buildPairRequest(): ByteArray {
        val publicKey = generateKeyForPairing()
        val token = pairingToken ?: throw IllegalStateException("No pairing token")

        return WireFormat.buildPairRequest(
            deviceName = deviceName,
            publicKey = publicKey,
            deviceID = deviceID,
            pairingToken = token,
            deviceType = DeviceType.WATCH,
            caps = watchCaps()
        )
    }

    private val bleListener = object : BLEClient.Listener {
        override fun onConnectionChanged(connected: Boolean, deviceAddress: String) {
            if (connected) {
                _connectionState.value = ConnectionState.CONNECTED
                Log.i(TAG, "BLE connected to $deviceAddress")

                // Initiate ECDH and send our public key to the Mac
                val publicKey = challengeHandler.initiateECDH()
                bleClient?.sendSessionKey(publicKey)

                // If we're in pairing mode, send the pair request
                if (pairingToken != null) {
                    val pairReq = buildPairRequest()
                    bleClient?.sendPairingData(pairReq)
                }
            } else {
                _connectionState.value = ConnectionState.DISCONNECTED
                Log.i(TAG, "BLE disconnected from $deviceAddress")
            }
        }

        override fun onChallengeReceived(data: ByteArray, deviceAddress: String) {
            try {
                val payload = WireFormat.decode(data) ?: return
                if (payload.first == WireFormat.TYPE_CHALLENGE_ISSUED) {
                    val challenge = challengeHandler.parseChallenge(payload.second)
                    _pendingChallenge.value = challenge
                    Log.i(TAG, "Challenge received: ${challenge.challengeID}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse challenge", e)
            }
        }

        override fun onSessionKeyReceived(data: ByteArray, deviceAddress: String) {
            try {
                challengeHandler.completeECDH(data)

                // Send signed Identify (proves we own the paired key)
                sendIdentify()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to complete ECDH", e)
                _connectionState.value = ConnectionState.FAILED
            }
        }

        override fun onPairingDataReceived(data: ByteArray, deviceAddress: String) {
            try {
                val payload = WireFormat.decode(data) ?: return
                if (payload.first == WireFormat.TYPE_PAIR_RESPONSE) {
                    handlePairResponse(payload.second)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle pairing data", e)
            }
        }

        override fun onDeviceDiscovered(deviceAddress: String) {
            if (_connectionState.value == ConnectionState.SCANNING) {
                _connectionState.value = ConnectionState.CONNECTING
                bleClient?.connect(deviceAddress)
            }
        }
    }

    private fun sendIdentify() {
        if (macDeviceID == null) return

        val signData = deviceID.toByteArray() + challengeHandler.getSessionPublicKey()
        val signature = keystoreManager.sign(signData, SIGNING_KEY_ALIAS)

        bleClient?.sendIdentify(
            deviceID = deviceID,
            deviceName = deviceName,
            signature = signature,
            deviceType = DeviceType.WATCH
        )
        _connectionState.value = ConnectionState.IDENTIFIED
        Log.i(TAG, "Identify sent (WATCH)")
    }

    private fun handlePairResponse(payload: ByteArray) {
        try {
            val response = dev.touchbridge.core.proto.PairResponse.parseFrom(payload)
            if (response.accepted) {
                prefs.edit()
                    .putString(KEY_MAC_ID, response.deviceId)
                    .putString(KEY_MAC_NAME, "Mac")
                    .putString(KEY_DEVICE_ID, deviceID)
                    .apply()
                macDeviceID = response.deviceId
                _paired.value = true
                pairingToken = null
                Log.i(TAG, "Pairing accepted by Mac: ${response.deviceId}")

                sendIdentify()
            } else {
                _connectionState.value = ConnectionState.FAILED
                Log.w(TAG, "Pairing rejected by Mac")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse pair response", e)
            _connectionState.value = ConnectionState.FAILED
        }
    }
}
