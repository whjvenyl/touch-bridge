package dev.touchbridge.android.core

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import dev.touchbridge.android.Constants

/**
 * BLE GATT client for Android.
 *
 * Connects to the Mac daemon's GATT peripheral and handles:
 * - Service/characteristic discovery
 * - ECDH session key exchange
 * - Challenge reception (via notifications)
 * - Signed response transmission
 * - Pairing data exchange
 *
 * Equivalent to iOS BLEClient (CBCentralManager).
 */
@SuppressLint("MissingPermission") // Permissions checked in UI layer
class BLEClient(private val context: Context) {

    companion object {
        private const val TAG = "BLEClient"
    }

    interface Listener {
        fun onConnectionChanged(connected: Boolean, deviceAddress: String)
        fun onChallengeReceived(data: ByteArray, deviceAddress: String)
        fun onSessionKeyReceived(data: ByteArray, deviceAddress: String)
        fun onPairingDataReceived(data: ByteArray, deviceAddress: String)
        fun onDeviceDiscovered(deviceAddress: String)
    }

    var listener: Listener? = null

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null
    private var isScanning = false
    private var currentScanUuid: java.util.UUID? = null

    private val descriptorWriteQueue = java.util.ArrayDeque<BluetoothGattDescriptor>()
    private var isWritingDescriptor = false
    private var pendingNotifyCount = 0

    // Characteristic write queue — Android BLE allows only one outstanding
    // writeCharacteristic at a time. Calls that arrive while a write is in
    // progress are queued and flushed in onCharacteristicWrite.
    private data class PendingWrite(val char: BluetoothGattCharacteristic, val payload: ByteArray)
    private val writeQueue = java.util.ArrayDeque<PendingWrite>()
    private var isWriting = false

    // Discovered characteristics
    private var sessionKeyChar: BluetoothGattCharacteristic? = null
    private var challengeChar: BluetoothGattCharacteristic? = null
    private var responseChar: BluetoothGattCharacteristic? = null
    private var pairingChar: BluetoothGattCharacteristic? = null

    // Discovered devices
    private val discoveredDevices = mutableMapOf<String, BluetoothDevice>()

    val isConnected: Boolean get() = gatt != null
    val discoveredDeviceAddresses: List<String> get() = discoveredDevices.keys.toList()

    // MARK: - Scanning

    fun startScanning(serviceUuid: java.util.UUID? = null) {
        if (isScanning) return
        
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (bluetoothManager?.adapter?.isEnabled != true) {
            Log.e(TAG, "Bluetooth is disabled")
            return
        }

        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "BluetoothLeScanner not available")
            return
        }
        this.scanner = scanner
        this.currentScanUuid = serviceUuid

        discoveredDevices.clear()
        
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? android.location.LocationManager
        val isLocationEnabled = locationManager?.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) == true ||
                                locationManager?.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER) == true
        
        Log.i(TAG, "Starting scan. Location enabled: $isLocationEnabled")

        val scanUuid = currentScanUuid ?: Constants.SERVICE_UUID
        Log.i(TAG, "Starting scan. Target Service UUID: $scanUuid")

        val filters = if (currentScanUuid != null) {
            listOf(
                ScanFilter.Builder()
                    .setServiceUuid(ParcelUuid(scanUuid))
                    .build()
            )
        } else {
            // Broad scan if no specific UUID provided from pairing yet
            emptyList()
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()

        try {
            // If scanning with filter doesn't find anything, we might need to scan broadly 
            // and filter manually in onScanResult. But for now, let's stick to the filter 
            // and add more logging.
            scanner.startScan(filters, settings, scanCallback)
            
            // Also try a broad scan for debugging if no results found? 
            // No, let's just log every result for now to see what's happening.
            isScanning = true
            Log.i(TAG, "Started scanning for TouchBridge Mac")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start scan", e)
        }
    }

    fun stopScanning() {
        if (!isScanning) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping scan", e)
        }
        isScanning = false
        Log.i(TAG, "Stopped scanning")
    }

    // MARK: - Connection

    fun connect(deviceAddress: String) {
        val device = discoveredDevices[deviceAddress] ?: return
        stopScanning()
        
        // Connect on main thread for better stability across Android versions
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            Log.i(TAG, "Connecting to $deviceAddress (on main thread)")
        }
    }

    fun disconnect() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        sessionKeyChar = null
        challengeChar = null
        responseChar = null
        pairingChar = null
    }

    // MARK: - Write Operations

    /**
     * Queue a characteristic write. Android BLE allows only one outstanding
     * writeCharacteristic at a time — if a write is already in progress, the
     * new write is queued and flushed when onCharacteristicWrite fires.
     */
    private fun queueWrite(char: BluetoothGattCharacteristic, payload: ByteArray): Boolean {
        val g = gatt ?: return false
        if (isWriting) {
            writeQueue.add(PendingWrite(char, payload))
            Log.i(TAG, "Write queued (${payload.size} bytes) — another write in progress")
            return true
        }
        char.value = payload
        isWriting = true
        val ok = g.writeCharacteristic(char)
        if (!ok) {
            isWriting = false
            Log.e(TAG, "writeCharacteristic failed immediately (${payload.size} bytes)")
        }
        return ok
    }

    private fun processWriteQueue() {
        if (isWriting || writeQueue.isEmpty()) return
        val g = gatt ?: return
        val pending = writeQueue.poll() ?: return
        pending.char.value = pending.payload
        isWriting = true
        val ok = g.writeCharacteristic(pending.char)
        if (!ok) {
            isWriting = false
            Log.e(TAG, "Queued write failed (${pending.payload.size} bytes)")
            // Try the next one
            processWriteQueue()
        } else {
            Log.i(TAG, "Flushed queued write (${pending.payload.size} bytes)")
        }
    }

    /**
     * Send a challenge response (type 4) — encrypted payload with wire format header.
     * The caller provides the already-encrypted payload; we prepend the header.
     */
    fun sendResponse(encryptedPayload: ByteArray): Boolean {
        val char = responseChar ?: return false
        val framed = WireFormat.encode(WireFormat.TYPE_CHALLENGE_RESPONSE, encryptedPayload)
        return queueWrite(char, framed)
    }

    /**
     * Send ECDH session key (raw public key bytes, no wire format header —
     * this is the key exchange phase before the protocol session is established).
     */
    fun sendSessionKey(data: ByteArray): Boolean {
        val char = sessionKeyChar ?: return false
        return queueWrite(char, data)
    }

    /**
     * Send pairing data (type 1) — pair request with wire format header.
     */
    fun sendPairingData(payload: ByteArray): Boolean {
        val char = pairingChar ?: run { Log.e(TAG, "sendPairingData: pairingChar is null"); return false }
        return queueWrite(char, payload)
    }

    /**
     * Send an identify message (type 6) — after ECDH on reconnect.
     * The signature proves possession of the paired private key.
     *
     * Sent on the pairing characteristic (not response) because the daemon
     * routes Identify messages through didReceivePairingData. The response
     * characteristic is for ChallengeResponse/Error only.
     */
    fun sendIdentify(
        deviceID: String,
        deviceName: String,
        signature: ByteArray,
        deviceType: dev.touchbridge.android.proto.DeviceType = dev.touchbridge.android.proto.DeviceType.PHONE
    ): Boolean {
        val char = pairingChar ?: return false
        val g = gatt ?: return false
        val framed = WireFormat.buildIdentify(deviceID, deviceName, signature, deviceType)
        char.value = framed
        return g.writeCharacteristic(char)
    }

    /**
     * Send an error message (type 5).
     */
    fun sendError(code: Int, description: String, challengeID: String? = null): Boolean {
        val char = responseChar ?: return false
        val g = gatt ?: return false
        val framed = WireFormat.buildError(code, description, challengeID)
        char.value = framed
        return g.writeCharacteristic(char)
    }

    // MARK: - Scan Callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val address = device.address
            val scanRecord = result.scanRecord
            
            // Log everything for now to help debug
            Log.d(TAG, "ScanResult: $address, Name: ${device.name}, UUIDs: ${scanRecord?.serviceUuids}")

            if (!discoveredDevices.containsKey(address)) {
                // If we have a filter, onScanResult should only be called for matching devices.
                // But we check manually just in case of system filter issues.
                val uuids = scanRecord?.serviceUuids?.map { it.uuid } ?: emptyList()
                val targetUuid = currentScanUuid ?: Constants.SERVICE_UUID
                
                if (uuids.contains(targetUuid) || device.name?.contains("TouchBridge", ignoreCase = true) == true) {
                    discoveredDevices[address] = device
                    Log.i(TAG, "Discovered TouchBridge Mac: $address (RSSI: ${result.rssi})")
                    listener?.onDeviceDiscovered(address)
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            isScanning = false
        }
    }

    // MARK: - GATT Callback

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address
            Log.i(TAG, "onConnectionStateChange: device=$address, status=$status, newState=$newState")

            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "GATT error for $address: $status")
                disconnect()
                listener?.onConnectionChanged(false, address)
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to Mac: $address")
                    // Request a larger MTU before service discovery.
                    // The default BLE ATT MTU is 23 (20 bytes payload), which
                    // truncates the 65-byte P-256 public key sent during ECDH.
                    // Request 512 to accommodate all protocol messages.
                    gatt.requestMtu(512)
                    // Service discovery is deferred to onMtuChanged so that
                    // the larger MTU is in effect before any data exchange.
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from Mac: $address")
                    this@BLEClient.gatt = null
                    listener?.onConnectionChanged(false, address)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "onMtuChanged: mtu=$mtu, status=$status")
            // MTU negotiation complete — now discover services.
            // If MTU request failed, proceed anyway with default MTU
            // (service discovery still works, but large payloads may truncate).
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            Log.i(TAG, "onServicesDiscovered: status=$status")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: $status")
                return
            }

            // The daemon generates a random service UUID at first run and embeds
            // it in the QR pairing payload. Use the UUID we scanned for (from the
            // QR code) to look up the service — not the hardcoded fallback.
            val serviceUuid = currentScanUuid ?: Constants.SERVICE_UUID
            val service = gatt.getService(serviceUuid)
            if (service == null) {
                Log.e(TAG, "TouchBridge service not found (looked for $serviceUuid)")
                return
            }

            sessionKeyChar = service.getCharacteristic(Constants.SESSION_KEY_CHAR_UUID)
            challengeChar = service.getCharacteristic(Constants.CHALLENGE_CHAR_UUID)
            responseChar = service.getCharacteristic(Constants.RESPONSE_CHAR_UUID)
            pairingChar = service.getCharacteristic(Constants.PAIRING_CHAR_UUID)

            Log.i(TAG, "Characteristics discovered")

            // Subscribe to notifications sequentially.
            // The ECDH session key exchange is deferred until all notification
            // subscriptions complete — the daemon sends its session key back
            // via notify, so we must be subscribed before writing our key.
            pendingNotifyCount = 0
            val charsToNotify = listOf(challengeChar, sessionKeyChar, pairingChar)
            for (char in charsToNotify) {
                if (char != null) pendingNotifyCount++
            }
            enableNotifications(gatt, challengeChar)
            enableNotifications(gatt, sessionKeyChar)
            enableNotifications(gatt, pairingChar)

            // If no characteristics need notification subscription (edge case),
            // fire the callback immediately.
            if (pendingNotifyCount == 0) {
                listener?.onConnectionChanged(true, gatt.device.address)
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            Log.i(TAG, "onDescriptorWrite: status=$status")
            isWritingDescriptor = false
            processDescriptorQueue(gatt)

            // When all notification subscriptions are complete, the connection
            // is ready for the ECDH key exchange. The daemon responds to our
            // session key write with a notify, so we must be subscribed first.
            if (pendingNotifyCount > 0) {
                pendingNotifyCount--
                if (pendingNotifyCount == 0) {
                    Log.i(TAG, "All notifications subscribed — connection ready")
                    listener?.onConnectionChanged(true, gatt.device.address)
                }
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            val data = characteristic.value ?: return
            val address = gatt.device.address

            when (characteristic.uuid) {
                Constants.CHALLENGE_CHAR_UUID -> {
                    // Strip wire format header [version][type] from challenge
                    val decoded = WireFormat.decode(data)
                    val payload = decoded?.second ?: data
                    Log.i(TAG, "Challenge received (${payload.size} bytes, type=${decoded?.first})")
                    listener?.onChallengeReceived(payload, address)
                }
                Constants.SESSION_KEY_CHAR_UUID -> {
                    // Session key is raw ECDH public key bytes (no wire format header)
                    Log.i(TAG, "Session key received (${data.size} bytes)")
                    listener?.onSessionKeyReceived(data, address)
                }
                Constants.PAIRING_CHAR_UUID -> {
                    // Strip wire format header from pairing response
                    val decoded = WireFormat.decode(data)
                    val payload = decoded?.second ?: data
                    Log.i(TAG, "Pairing data received (${payload.size} bytes, type=${decoded?.first})")
                    listener?.onPairingDataReceived(payload, address)
                }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            isWriting = false
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Write failed for ${characteristic.uuid}: $status")
            }
            // Flush any pending writes that were queued while this write was in progress.
            processWriteQueue()
        }
    }

    private fun enableNotifications(gatt: BluetoothGatt, char: BluetoothGattCharacteristic?) {
        char ?: return
        gatt.setCharacteristicNotification(char, true)
        val descriptor = char.getDescriptor(Constants.CCCD_UUID)
        if (descriptor != null) {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            descriptorWriteQueue.add(descriptor)
            processDescriptorQueue(gatt)
        }
    }

    private fun processDescriptorQueue(gatt: BluetoothGatt) {
        if (isWritingDescriptor || descriptorWriteQueue.isEmpty()) return
        val descriptor = descriptorWriteQueue.poll() ?: return
        isWritingDescriptor = true
        gatt.writeDescriptor(descriptor)
    }
}
