package dev.touchbridge.wear.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the BLE connection while the watch is on-wrist.
 *
 * Hybrid lifecycle:
 * - While on-wrist (screen on or interactive), keeps a persistent BLE GATT
 *   connection via WearAuthManager.
 * - When the watch goes to sleep (screen off / ambient), the GATT connection
 *   drops. The relay (ChallengeListenerService) wakes the watch when a
 *   challenge arrives, and this service reconnects BLE to sign directly.
 *
 * The foreground notification is minimal (low importance) to avoid annoyance.
 */
class TouchBridgeWearService : Service() {

    companion object {
        private const val TAG = "WearService"
        private const val CHANNEL_PERSISTENT = "touchbridge_persistent"
        private const val CHANNEL_CHALLENGE = "touchbridge_challenge"
        private const val NOTIF_ID = 1

        fun start(context: Context) {
            val intent = Intent(context, TouchBridgeWearService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TouchBridgeWearService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var authManager: WearAuthManager
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate")

        authManager = WearAuthManager(applicationContext)
        createNotificationChannels()

        // Start foreground immediately (Android 14+ requires within 5s)
        startForeground(NOTIF_ID, buildPersistentNotification())

        // Observe connection state and reconnect when needed
        scope.launch {
            authManager.connectionState.collectLatest { state ->
                Log.d(TAG, "Connection state: $state")
                when (state) {
                    WearAuthManager.ConnectionState.DISCONNECTED -> {
                        if (authManager.paired.value) {
                            // Try to reconnect if we're paired
                            authManager.connectForAuth()
                        }
                    }
                    else -> {}
                }
            }
        }

        // Connect if already paired
        if (authManager.paired.value) {
            authManager.connectForAuth()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand")
        return START_STICKY  // Restart if killed
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "onDestroy")
        authManager.disconnect()
        wakeLock?.release()
        scope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)

            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_PERSISTENT,
                "TouchBridge Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Persistent connection to your Mac"
                setShowBadge(false)
            })

            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_CHALLENGE,
                "Auth Requests",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Authentication request notifications"
                enableVibration(true)
            })
        }
    }

    private fun buildPersistentNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_PERSISTENT)
            .setContentTitle("TouchBridge")
            .setContentText("Connected to Mac")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
