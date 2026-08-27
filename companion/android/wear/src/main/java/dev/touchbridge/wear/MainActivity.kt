package dev.touchbridge.wear

import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.*
import dev.touchbridge.wear.core.TouchBridgeWearService
import dev.touchbridge.wear.core.WearAuthManager

class MainActivity : ComponentActivity() {

    private lateinit var authManager: WearAuthManager
    private lateinit var vibrator: Vibrator

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        authManager = WearAuthManager(applicationContext)
        vibrator = getSystemService(Vibrator::class.java)

        // Start the foreground service if paired
        if (authManager.paired.value) {
            TouchBridgeWearService.start(this)
        }

        setContent {
            MaterialTheme {
                val paired by authManager.paired.collectAsState()
                val connectionState by authManager.connectionState.collectAsState()
                val pendingChallenge by authManager.pendingChallenge.collectAsState()

                if (pendingChallenge != null) {
                    // Vibrate to alert
                    LaunchedEffect(pendingChallenge) {
                        vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
                    }

                    AuthRequestScreen(
                        challenge = pendingChallenge!!,
                        biometricMode = authManager.biometricMode,
                        onApprove = {
                            val signature = authManager.signChallenge(pendingChallenge!!)
                            if (signature != null) {
                                authManager.sendChallengeResponse(pendingChallenge!!.challengeID, signature)
                                vibrator.vibrate(VibrationEffect.createOneShot(100, VibrationEffect.DEFAULT_AMPLITUDE))
                            }
                        },
                        onDeny = {
                            authManager.sendError(1002, "User denied", pendingChallenge!!.challengeID)
                            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 50, 50, 50), -1))
                        }
                    )
                } else if (paired) {
                    PairedStatusScreen(
                        connectionState = connectionState,
                        biometricMode = authManager.biometricMode,
                        onToggleBiometric = {
                            val newMode = if (authManager.biometricMode == WearAuthManager.BiometricMode.SECURE)
                                WearAuthManager.BiometricMode.QUICK else WearAuthManager.BiometricMode.SECURE
                            authManager.setBiometricMode(newMode)
                        },
                        onUnpair = {
                            TouchBridgeWearService.stop(this)
                            authManager.unpair()
                        }
                    )
                } else {
                    PairingScreen(
                        onPair = { macId, token, macName ->
                            authManager.startPairing(macId, token, macName)
                            TouchBridgeWearService.start(this)
                        }
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Don't stop the service on activity destroy — it should persist
    }
}

@Composable
fun AuthRequestScreen(
    challenge: dev.touchbridge.core.ChallengeData,
    biometricMode: WearAuthManager.BiometricMode,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
) {
    ScalingLazyColumn(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        item {
            Text(text = "🔐", fontSize = 32.sp, modifier = Modifier.padding(bottom = 8.dp))
        }
        item {
            Text(
                text = "Auth Request",
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
                color = Color.White,
            )
        }
        item {
            Text(
                text = challenge.reason,
                fontSize = 13.sp,
                color = Color.LightGray,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )
        }
        item { Spacer(modifier = Modifier.height(12.dp)) }

        item {
            Chip(
                onClick = onApprove,
                label = { Text("Approve", fontWeight = FontWeight.SemiBold) },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF30D158)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }
        item {
            Chip(
                onClick = onDeny,
                label = { Text("Deny") },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF48484A)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }

        if (biometricMode == WearAuthManager.BiometricMode.SECURE) {
            item {
                Text(
                    text = "Unlock required",
                    fontSize = 10.sp,
                    color = Color.Gray,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
        }
    }
}

@Composable
fun PairedStatusScreen(
    connectionState: WearAuthManager.ConnectionState,
    biometricMode: WearAuthManager.BiometricMode,
    onToggleBiometric: () -> Unit,
    onUnpair: () -> Unit,
) {
    ScalingLazyColumn(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        item {
            Text(text = "🔐", fontSize = 28.sp)
        }
        item {
            Text(
                text = "TouchBridge",
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                color = Color.White,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
        item {
            val statusText = when (connectionState) {
                WearAuthManager.ConnectionState.IDENTIFIED -> "Connected"
                WearAuthManager.ConnectionState.CONNECTED -> "Connecting..."
                WearAuthManager.ConnectionState.CONNECTING -> "Connecting..."
                WearAuthManager.ConnectionState.SCANNING -> "Scanning..."
                WearAuthManager.ConnectionState.DISCONNECTED -> "Disconnected"
                WearAuthManager.ConnectionState.FAILED -> "Failed"
            }
            Text(
                text = statusText,
                fontSize = 12.sp,
                color = if (connectionState == WearAuthManager.ConnectionState.IDENTIFIED)
                    Color(0xFF30D158) else Color.Gray,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
        item { Spacer(modifier = Modifier.height(12.dp)) }
        item {
            Chip(
                onClick = onToggleBiometric,
                label = {
                    Text(
                        if (biometricMode == WearAuthManager.BiometricMode.SECURE)
                            "Mode: Secure" else "Mode: Quick"
                    )
                },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF48484A)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }
        item {
            Chip(
                onClick = onUnpair,
                label = { Text("Unpair", color = Color(0xFFFF453A)) },
                colors = ChipDefaults.chipColors(backgroundColor = Color(0xFF1C1C1E)),
                modifier = Modifier.fillMaxWidth(0.9f),
            )
        }
    }
}

@Composable
fun PairingScreen(
    onPair: (macId: String, token: ByteArray, macName: String) -> Unit,
) {
    // TODO: QR scanning on Wear OS is limited — the user will need to
    // initiate pairing from the phone app, which sends the pairing data
    // via Wearable Data Layer. For now, show instructions.
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text = "🔐", fontSize = 28.sp)
        Text(
            text = "TouchBridge",
            fontWeight = FontWeight.Bold,
            fontSize = 14.sp,
            color = Color.White,
            modifier = Modifier.padding(top = 4.dp)
        )
        Text(
            text = "Start pairing from your phone",
            fontSize = 11.sp,
            color = Color.Gray,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
        )
    }
}
