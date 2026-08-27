package dev.touchbridge.wear

import android.content.Intent
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import dev.touchbridge.wear.core.TouchBridgeWearService
import org.json.JSONObject

/**
 * Listens for auth challenge messages from the Android phone companion app.
 *
 * This is the RELAY FALLBACK path. When the watch's direct BLE connection to
 * the Mac is asleep (Doze / ambient mode), the phone receives the challenge
 * from the Mac and forwards it via the Wearable Data Layer.
 *
 * On receiving a relay challenge:
 * 1. Start the foreground service (which reconnects BLE to the Mac)
 * 2. Store the challenge for the UI to display
 * 3. The UI will prompt the user; when approved, the watch signs directly
 *    over BLE (not via relay) — the relay is only a wake-up mechanism.
 *
 * Message path: /touchbridge/challenge
 */
class ChallengeListenerService : WearableListenerService() {

    companion object {
        const val CHALLENGE_PATH = "/touchbridge/challenge"
        const val RESPONSE_PATH = "/touchbridge/response"

        var pendingChallenge: PendingChallenge? = null
        var onChallengeReceived: ((PendingChallenge) -> Unit)? = null
    }

    data class PendingChallenge(
        val challengeID: String,
        val reason: String,
        val macName: String,
        val user: String,
        val sourceNodeId: String,
    )

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path == CHALLENGE_PATH) {
            val json = JSONObject(String(messageEvent.data))

            val challenge = PendingChallenge(
                challengeID = json.optString("challengeID", ""),
                reason = json.optString("reason", "Authentication"),
                macName = json.optString("macName", "Mac"),
                user = json.optString("user", ""),
                sourceNodeId = messageEvent.sourceNodeId,
            )

            pendingChallenge = challenge
            onChallengeReceived?.invoke(challenge)

            // Wake up the foreground service to reconnect BLE
            TouchBridgeWearService.start(this)
        }
    }
}
