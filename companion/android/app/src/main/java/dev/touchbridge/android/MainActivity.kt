package dev.touchbridge.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.fragment.app.FragmentActivity
import dev.touchbridge.android.ui.screens.*
import dev.touchbridge.android.ui.theme.TouchBridgeTheme
import kotlinx.coroutines.flow.collectLatest

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            TouchBridgeTheme {
                val context = LocalContext.current
                val viewModel: TouchBridgeViewModel = viewModel(
                    factory = TouchBridgeViewModel.Factory(applicationContext)
                )
                val uiState by viewModel.uiState.collectAsState()

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

                val launcher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestMultiplePermissions()
                ) { permissions ->
                    val allGranted = permissions.entries.all { it.value }
                    if (allGranted && uiState.isPaired) {
                        viewModel.startScanning()
                    }
                }

                LaunchedEffect(uiState.isPaired) {
                    if (uiState.isPaired) {
                        val hasPermissions = permissionsToRequest.all {
                            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
                        }
                        if (hasPermissions) {
                            viewModel.startScanning()
                        } else {
                            launcher.launch(permissionsToRequest)
                        }
                    }
                }

                LaunchedEffect(Unit) {
                    viewModel.authRequest.collectLatest { challenge ->
                        val executor = ContextCompat.getMainExecutor(this@MainActivity)
                        val biometricPrompt = BiometricPrompt(
                            this@MainActivity,
                            executor,
                            object : BiometricPrompt.AuthenticationCallback() {
                                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                                    super.onAuthenticationSucceeded(result)
                                    val signature = result.cryptoObject?.signature ?: return
                                    signature.update(challenge.encryptedNonce)
                                    val signedNonce = signature.sign()
                                    viewModel.sendAuthResponse(challenge.challengeID, signedNonce)
                                }
                                
                                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                    super.onAuthenticationError(errorCode, errString)
                                    // Optionally log or show error
                                }
                            }
                        )

                        val promptInfo = BiometricPrompt.PromptInfo.Builder()
                            .setTitle("TouchBridge Authentication")
                            .setSubtitle(challenge.reason)
                            .setNegativeButtonText("Cancel")
                            .setConfirmationRequired(false)
                            .build()

                        try {
                            val signature = viewModel.keystoreManager.createSignature(Constants.SIGNING_KEY_ALIAS)
                            biometricPrompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(signature))
                        } catch (e: Exception) {
                            android.util.Log.e("MainActivity", "Failed to init biometric prompt", e)
                        }
                    }
                }

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    if (uiState.isPaired) {
                        MainScreen(viewModel = viewModel, uiState = uiState)
                    } else {
                        OnboardingScreen(viewModel = viewModel)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: TouchBridgeViewModel, uiState: TouchBridgeUiState) {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = currentRoute == "home" || currentRoute == null,
                    onClick = { 
                        navController.navigate("home") {
                            popUpTo(navController.graph.startDestinationId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_lock_idle_lock), "Home") },
                    label = { Text("Home") }
                )
                NavigationBarItem(
                    selected = currentRoute == "activity",
                    onClick = { 
                        navController.navigate("activity") {
                            popUpTo(navController.graph.startDestinationId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_recent_history), "Activity") },
                    label = { Text("Activity") }
                )
                NavigationBarItem(
                    selected = currentRoute == "settings",
                    onClick = { 
                        navController.navigate("settings") {
                            popUpTo(navController.graph.startDestinationId) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_preferences), "Settings") },
                    label = { Text("Settings") }
                )
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = "home",
            modifier = Modifier.padding(padding)
        ) {
            composable("home") {
                HomeScreen(viewModel = viewModel, uiState = uiState)
            }
            composable("activity") {
                ActivityScreen(viewModel = viewModel, uiState = uiState)
            }
            composable("settings") {
                SettingsScreen(viewModel = viewModel, uiState = uiState)
            }
        }
    }
}

@Composable
fun OnboardingScreen(viewModel: TouchBridgeViewModel) {
    var showPairing by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Spacer(modifier = Modifier.weight(1f))

        // Icon
        Text(
            text = "🔐",
            fontSize = 72.sp,
            modifier = Modifier.padding(bottom = 16.dp)
        )

        Text(
            text = "TouchBridge",
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )

        Text(
            text = "Use your fingerprint or face to\nauthenticate on your Mac.",
            fontSize = 16.sp,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp, bottom = 32.dp)
        )

        // Features
        FeatureItem(icon = "🔒", title = "Secure", desc = "Keys stored in hardware security module")
        FeatureItem(icon = "📡", title = "Wireless", desc = "Connects via Bluetooth LE")
        FeatureItem(icon = "👆", title = "Biometric", desc = "Fingerprint or face — no passwords")

        Spacer(modifier = Modifier.weight(1f))

        if (showPairing) {
            PairingScreen(viewModel = viewModel)
        } else {
            Button(
                onClick = { showPairing = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
            ) {
                Text("Get Started", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
fun FeatureItem(icon: String, title: String, desc: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(icon, fontSize = 24.sp, modifier = Modifier.padding(end = 16.dp))
        Column {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(desc, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
