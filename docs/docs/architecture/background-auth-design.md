# Background Authentication & Notifications — Design

> Status: **Planning** — architecture reviewed, not yet implemented.
> Last updated: 2026-08-27

## Problem

TouchBridge companion apps only receive authentication challenges when the app
is in the foreground (Android) or when the app is foregrounded after tapping a
basic notification (iOS). For TouchBridge to feel like a system service — the
way email, chat, and SMS apps receive messages — the companion apps must:

1. Keep the BLE connection alive in the background.
2. Notify the user when an auth request arrives, even if the phone is locked.
3. Let the user approve with minimal interaction (one tap + biometric).
4. Fall back to password gracefully if the user ignores the request.

## Target UX

When `sudo ls` runs on the Mac:

1. Mac daemon broadcasts the challenge over BLE to all connected, paired devices.
2. The phone (in pocket, locked) wakes the screen and shows a **time-sensitive**
   notification: "MacBook Pro wants you to approve: sudo".
3. The notification has one action button: **Approve**. Tapping the notification
   body opens the app to show details (reason, Mac name, user).
4. The user taps **Approve**. The phone unlocks (Face ID / fingerprint at the
   lock screen). The app comes to foreground and runs a **silent biometric
   check** — because the face was just detected at the lock screen, the second
   Face ID check typically passes without a visible prompt.
5. The app signs the nonce and sends the response over BLE.
6. `sudo ls` succeeds without a password prompt.

Total time: ~3 seconds from `sudo ls` to approval.

If the user ignores the notification, the daemon times out after 15 seconds and
falls back to password. The notification is **auto-dismissed** from the lock
screen when the challenge expires — no stale notifications.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Target UX when challenge arrives on locked phone | Wake screen + tap + biometric |
| 2 | Face ID when phone is locked | Silent biometric check (try `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` after unlock; fall back to full prompt if it fails) |
| 3 | Notification actions | "Approve" action button only. Tapping body opens app for details. Deny is implicit (ignore → timeout → password). |
| 4 | Focus mode / DND behavior | `.timeSensitive` interruption level (iOS 15+). Breaks through Focus modes. No special entitlement needed. |
| 5 | Android background architecture | Foreground service, scoped to paired state. Started after pairing, stopped on unpair. |
| 6 | Android BLE connection strategy | Adaptive keepalive — persistent GATT connection with low-power idle mode, low-latency active mode when challenge is pending. |
| 7 | Watch role | Watch first, phone fallback. Watch connects directly to Mac over BLE with its own signing key. Phone is fallback. (Largest scope — deferred to phase 3.) |
| 8 | Challenge dispatch order | Simultaneous broadcast to all connected devices. First response wins. Watch naturally wins (faster, no unlock needed). |
| 9 | Ignored notification behavior | Daemon timeout (15s) → password fallback. App auto-dismisses the notification when the challenge expires. |
| 10 | Notification permission timing | Request at first launch (current iOS behavior). |
| 11 | iOS notification handling | Main app — no Notification Service Extension. `bluetooth-central` keeps BLE alive in background; notification action foregrounds the app. |
| 12 | Implementation priority | Android first (biggest functional gap), then iOS polish, then Watch independent BLE. |
| 13 | Android persistent notification | Minimal, low-priority, visible ("TouchBridge — Connected to MacBook Pro"). Separate high-priority channel for challenge notifications. |
| 14 | Android auto-start | Auto-start on boot if paired. `LOCKED_BOOT_COMPLETED` for Direct Boot support. BLE connects before unlock; biometric approval requires unlock. |

## Implementation Plan

### Phase 1: Android Foreground Service

**Goal:** Android companion can receive and respond to auth challenges while
backgrounded, with a persistent BLE connection and proper notifications.

**Scope:**

1. **`TouchBridgeService`** — a foreground service that owns the BLE client,
   ECDH session, and challenge handler. The ViewModel becomes a thin UI layer
   that observes the service state.

   - `foregroundServiceType="connectedDevice"` on Android 14+
   - Starts after pairing completes; stops on unpair
   - Survives app being backgrounded or killed

2. **Notification channels:**
   - `CHANNEL_PERSISTENT` (`IMPORTANCE_LOW`) — "TouchBridge is running" with
     connection status text. No sound, no vibration. Small status bar icon.
   - `CHANNEL_CHALLENGE` (`IMPORTANCE_HIGH`) — auth request notifications with
     sound, vibration, and "Approve" action button.

3. **`BootReceiver`** — `BroadcastReceiver` for `LOCKED_BOOT_COMPLETED`:
   - Checks if a paired Mac exists in storage
   - If paired, starts `TouchBridgeService` in Direct Boot
   - BLE connection establishes before unlock; biometric prompt requires unlock

4. **Adaptive BLE keepalive:**
   - Request `CONNECTION_PRIORITY_LOW_POWER` when idle (saves battery)
   - Request `CONNECTION_PRIORITY_HIGH` when a challenge is received (low latency
     for response transmission)
   - Reconnect on disconnect with exponential backoff

5. **Challenge notification with "Approve" action:**
   - `PendingIntent` with action `APPROVE_CHALLENGE`
   - Tapping "Approve" opens `MainActivity` with the challenge data
   - `BiometricPrompt` runs (requires activity — use `MainActivity` or a
     transparent activity)
   - On approval, sign and send response via the service's BLE client

6. **`POST_NOTIFICATIONS` permission** (Android 13+) — requested at first launch.

7. **Manifest changes:**
   - `<service android:name=".TouchBridgeService" android:foregroundServiceType="connectedDevice" />`
   - `<receiver android:name=".BootReceiver" android:exported="true" android:directBootAware="true">` with `LOCKED_BOOT_COMPLETED` intent filter
   - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />`
   - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />`
   - `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />`
   - `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`

**Files to create:**
- `companion/android/app/src/main/java/dev/touchbridge/android/service/TouchBridgeService.kt`
- `companion/android/app/src/main/java/dev/touchbridge/android/service/BootReceiver.kt`
- `companion/android/app/src/main/java/dev/touchbridge/android/service/NotificationHelper.kt`

**Files to modify:**
- `companion/android/app/src/main/AndroidManifest.xml`
- `companion/android/app/src/main/java/dev/touchbridge/android/ui/screens/TouchBridgeViewModel.kt` (delegate to service)
- `companion/android/app/src/main/java/dev/touchbridge/android/core/BLEClient.kt` (lifecycle owned by service)
- `companion/android/app/src/main/java/dev/touchbridge/android/MainActivity.kt` (handle notification action intents)

### Phase 2: iOS Notification Polish

**Goal:** iOS companion delivers a polished, time-sensitive notification with
an "Approve" action and silent biometric check.

**Scope:**

1. **Notification category with "Approve" action:**
   - `UNNotificationCategory` with identifier `dev.touchbridge.challenge`
   - `UNNotificationAction` with identifier `APPROVE`, title "Approve",
     options `[.foreground]` (brings app to foreground when tapped)
   - Register the category at app launch via
     `UNUserNotificationCenter.setNotificationCategories`

2. **`.timeSensitive` interruption level:**
   - Set `content.interruptionLevel = .timeSensitive` on challenge notifications
   - Breaks through Focus modes / DND
   - Available iOS 15+, no special entitlement

3. **`UNUserNotificationCenterDelegate`:**
   - Implement `userNotificationCenter(_:didReceive:withCompletionHandler:)`
   - Handle `APPROVE` action: run silent biometric check, sign, send response
   - Handle notification body tap: open `AuthRequestView` with challenge details

4. **Silent biometric check:**
   - When the app foregrounds via notification action, call
     `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`
   - Because Face ID just detected the face at the lock screen, this typically
     passes without a visible prompt (or with a brief checkmark)
   - If it fails, fall back to a full Face ID prompt with `localizedReason`
   - If the user cancels, send no response (daemon times out → password)

5. **Auto-dismiss notification on timeout:**
   - Track the challenge expiry time locally
   - Schedule a `UNNotificationRequest` removal at expiry
   - Or: use `UNTimeIntervalNotificationTrigger` to post a removal request
   - Removes the notification from the lock screen when the challenge expires

6. **Notification permission at first launch (current behavior, kept):**
   - `AppDelegate` requests `.alert + .sound + .timeSensitive` (add `.timeSensitive`
     to the authorization options)
   - Consider adding a brief pre-prompt explanation screen before the system
     prompt to improve grant rate (optional)

**Files to modify:**
- `companion/ios/TouchBridge/App/AppDelegate.swift` (register notification category, add `.timeSensitive` to auth options)
- `companion/ios/TouchBridge/Core/CompanionCoordinator.swift` (notification category, action handling, silent biometric, auto-dismiss)
- `companion/ios/TouchBridge/Core/ChallengeHandler.swift` (silent biometric check path)
- `companion/ios/TouchBridge/Resources/Info.plist` (no changes needed — `bluetooth-central` already declared)

### Phase 3: Watch Independent BLE

**Goal:** Watch connects directly to the Mac over BLE with its own signing key.
The Mac tries the watch first (lower latency — on wrist, no unlock needed),
then falls back to the phone.

**Scope:**

1. **Watch pairing:**
   - Watch generates its own signing key in Secure Enclave / Android Keystore
   - Watch pairs with the Mac separately (or as part of phone pairing with
     a "also pair my watch" option)
   - Mac stores the watch's public key and deviceID in Keychain

2. **Watch BLE client:**
   - WatchOS: `WCSession` is replaced by direct `CBCentralManager` BLE connection
   - Wear OS: `BluetoothLeScanner` in a Wear OS foreground service
   - Watch does its own ECDH, identify, challenge response

3. **Watch biometric prompt:**
   - watchOS: No Face ID on watch — use wrist detection + double-click side
     button (like Apple Pay on Apple Watch)
   - Wear OS: Wear OS biometric prompt (fingerprint/PIN if available, else
     device unlock is sufficient)

4. **Mac daemon dispatch:**
   - Simultaneous broadcast (current behavior) — watch naturally wins because
     it's faster (no phone unlock needed)
   - No daemon changes needed for dispatch order
   - Daemon needs to handle watch device type (already supports `TBDeviceType.watch`)

5. **Phone-watch fallback:**
   - If the watch is disconnected/off-wrist, the phone handles the challenge
   - If both are available, first response wins (watch usually responds first)
   - No explicit priority logic needed

**Files to create/modify:**
- `companion/ios/TouchBridgeWatch/Core/WatchBLEClient.swift` (new — direct BLE)
- `companion/ios/TouchBridgeWatch/Core/WatchCoordinator.swift` (new — replaces WatchConnectivityManager)
- `companion/ios/TouchBridgeWatch/Core/WatchSigningProvider.swift` (new — Secure Enclave key)
- `companion/android/wear/` — Wear OS BLE client and signing (new)
- `mac/daemon/Sources/TouchBridgeCore/DaemonCoordinator.swift` (watch device type handling — may already be sufficient)

## Security Considerations

- **Silent biometric check does not weaken security:** Face ID still runs — it
  just doesn't show a full UI overlay when the face was just detected. The
  biometric evaluation is the same; only the presentation differs.

- **No "Deny" button:** Intentional. Accidental denial in the pocket could lock
  the user out of their own sudo. Timeout → password fallback is the safe path.

- **`.timeSensitive` notifications:** Auth requests are genuinely urgent (blocking
  a terminal). Time-sensitive is the correct interruption level. The notification
  still respects the ringer switch — it won't blast sound on silent.

- **Android foreground service:** The persistent notification is the user's
  indicator that TouchBridge is running and consuming battery. The user can
  stop the service by unpairing or force-stopping the app.

- **Watch independent signing key:** The watch's signing key is separate from
  the phone's. Compromising one device doesn't compromise the other. The Mac
  stores both keys and can verify responses from either.

- **No relay server:** All communication is over BLE. No auth metadata is sent
  to any server. No APNs/FCM push notifications are used.

## Battery Impact

| Platform | Idle | Active (challenge) |
|----------|------|--------------------|
| iOS | ~1-2%/day (bluetooth-central background mode) | ~0.1% per auth (BLE + Face ID + signing) |
| Android | ~2-3%/day (foreground service + low-power GATT) | ~0.2% per auth (BLE + biometric + signing) |
| Watch | ~1-2%/day (BLE connected, wrist detection) | ~0.1% per auth (BLE + signing) |

Android is slightly higher due to foreground service overhead, but adaptive
connection parameters keep idle power low.

## Open Questions

- Should the iOS pre-prompt explanation screen be added before the notification
  permission request? (Currently decided: no, request at first launch directly.)
- Should the Android foreground service show connection status in the persistent
  notification text ("Connected" / "Searching…" / "Disconnected")? (Recommended:
  yes, but implementation detail.)
- For the watch, should wrist-raised be sufficient to approve, or should it
  require an explicit tap? (Apple Pay requires double-click side button; we
  should match that for security.)
