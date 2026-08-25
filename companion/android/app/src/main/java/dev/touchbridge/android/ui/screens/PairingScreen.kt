package dev.touchbridge.android.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import dev.touchbridge.android.ui.components.QrScanner

@Composable
fun PairingScreen(viewModel: TouchBridgeViewModel) {
    val context = LocalContext.current
    var manualInput by remember { mutableStateOf("") }
    var pairingState by remember { mutableStateOf("idle") } // idle, scanning, qr_scanning, connecting, paired, error

    val permissionsToRequest = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT
        )
    } else {
        arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION
        )
    }

    val bluetoothLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.entries.all { it.value }
        if (!allGranted) {
            pairingState = "error"
        }
    }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            pairingState = "qr_scanning"
        } else {
            pairingState = "error"
        }
    }

    fun hasBluetoothPermissions(): Boolean {
        return permissionsToRequest.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun startScanningWithPermission() {
        if (hasBluetoothPermissions()) {
            pairingState = "scanning"
            viewModel.startScanning()
        } else {
            bluetoothLauncher.launch(permissionsToRequest)
        }
    }

    fun processPairingJson(jsonString: String) {
        pairingState = "connecting"
        try {
            val json = org.json.JSONObject(jsonString)
            val macName = json.optString("macName", "Mac")
            val serviceUUID = json.optString("serviceUUID", "")
            if (serviceUUID.isBlank()) {
                pairingState = "error"
                return
            }
            // Extract pairing token (base64-encoded, one-time use from QR)
            val pairingToken: ByteArray? = if (json.has("pairingToken")) {
                dev.touchbridge.android.core.WireFormat.decodeBase64(json.getString("pairingToken"))
            } else null

            viewModel.completePairing(macName, serviceUUID, pairingToken)
            viewModel.startScanning()
            pairingState = "paired"
        } catch (e: Exception) {
            pairingState = "error"
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "Pair with your Mac",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 8.dp)
        )

        Text(
            text = "Run 'touchbridge pair' on your Mac,\nthen scan the QR code or paste JSON.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(bottom = 16.dp)
        )

        when (pairingState) {
            "idle" -> {
                OutlinedTextField(
                    value = manualInput,
                    onValueChange = { manualInput = it },
                    label = { Text("Pairing JSON") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    maxLines = 6,
                )

                Spacer(modifier = Modifier.height(12.dp))

                Button(
                    onClick = {
                        processPairingJson(manualInput)
                    },
                    enabled = manualInput.isNotBlank(),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Pair Manual")
                }

                Spacer(modifier = Modifier.height(8.dp))

                Button(
                    onClick = {
                        if (hasCameraPermission()) {
                            pairingState = "qr_scanning"
                        } else {
                            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Scan QR Code")
                }

                Spacer(modifier = Modifier.height(8.dp))

                OutlinedButton(
                    onClick = {
                        startScanningWithPermission()
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Scan for Nearby Mac (BLE)")
                }

                Spacer(modifier = Modifier.height(16.dp))
                
                val bluetoothManager = context.getSystemService(android.content.Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager
                if (bluetoothManager?.adapter?.isEnabled != true) {
                    Text(
                        text = "⚠️ Bluetooth is turned off",
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 12.sp
                    )
                }
            }

            "qr_scanning" -> {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                ) {
                    QrScanner(onScan = { result ->
                        processPairingJson(result)
                    })
                }
                Spacer(modifier = Modifier.height(16.dp))
                TextButton(onClick = { pairingState = "idle" }) {
                    Text("Cancel")
                }
            }

            "scanning" -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Scanning for Mac...")
                
                val uiState by viewModel.uiState.collectAsState()
                if (uiState.discoveredDevices.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("Found Devices:", fontWeight = FontWeight.SemiBold)
                    uiState.discoveredDevices.forEach { address ->
                        TextButton(onClick = { viewModel.connectTo(address) }) {
                            Text(address)
                        }
                    }
                }
                
                Spacer(modifier = Modifier.height(16.dp))
                TextButton(onClick = { pairingState = "idle" }) {
                    Text("Cancel")
                }
            }

            "connecting" -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Connecting...")
            }

            "paired" -> {
                Text(
                    text = "✅ Paired!",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            }

            "error" -> {
                Text(
                    text = "❌ Error occurred",
                    color = MaterialTheme.colorScheme.error
                )
                Text(
                    text = "Make sure permissions are granted and Bluetooth is on.",
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.error
                )
                Spacer(modifier = Modifier.height(8.dp))
                TextButton(onClick = { pairingState = "idle" }) {
                    Text("Try Again")
                }
            }
        }
    }
}
