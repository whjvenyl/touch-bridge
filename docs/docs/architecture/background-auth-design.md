# Background Authentication & Notifications — Design

> Status: **Planning** — architecture reviewed and hardened, not yet implemented.
> Last updated: 2026-08-27
> Review: passed one external agent review; all must-fix items incorporated.

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
   Face ID check typically passes without a visible prompt. If the face is not
   in frame, a full Face ID overlay shows — this is expected and not a bug.
5. The app signs the nonce and sends the response over BLE.
6. `sudo ls` succeeds without a password prompt.

Total time: ~3 seconds from `sudo ls` to approval.

If the user ignores the notification, the daemon times out and falls back to
password. The notification is **auto-dismissed** from the lock screen when the
challenge expires — no stale notifications.

## Timeout Semantics

There are **two distinct timeouts** — the plan must not conflate them:

| Timeout | Value | Source | Meaning |
|---------|-------|--------|---------|
| Challenge nonce TTL | 10s | `TouchBridgeConstants.challengeExpirySeconds` | The nonce is valid for 10s after issuance. The companion must sign and respond within this window. Enforced by `ChallengeManager.verify()`. |
| PAM global timeout | 15s | `TouchBridgeConstants.responseTimeoutSeconds`, passed by `SocketServer` via `policyEngine.authTimeout()` | How long `authenticateFromPAM` blocks before returning failure to PAM. Must be ≥ nonce TTL. |

**Auto-dismiss logic must use `expiryUnix` from `TBChallengeIssued`**, not a
hardcoded 15s. The notification should be dismissed when the nonce expires
(10s), not when the PAM timeout fires (15s) — the 5s gap is the daemon's
grace period for response transit, not the user's decision window.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Target UX when challenge arrives on locked phone | Wake screen + tap + biometric |
| 2 | Face ID when phone is locked | Silent biometric check: try `evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` after unlock. Not guaranteed silent — if face not in frame, full overlay shows. App must have `AuthRequestView` visible behind it as the fallback UI. Fall back to full prompt with `localizedReason` if silent check fails. |
| 3 | Notification actions | "Approve" action button only. Tapping body opens app for details. Deny is implicit (ignore → timeout → password). |
| 4 | Focus mode / DND behavior | `.timeSensitive` interruption level set on `UNMutableNotificationContent.interruptionLevel` (iOS 15+). Not a notification authorization option — the auth request uses `[.alert, .sound, .badge]`. |
| 5 | Android background architecture | Foreground service, scoped to paired state. Started after pairing, stopped on unpair. |
| 6 | Android BLE connection strategy | Adaptive keepalive — persistent GATT connection. `requestConnectionPriority()` is a hint, not a command — the Mac (`CBPeripheralManager`) controls the actual interval. Use it for battery optimization, not correctness. Reconnect with exponential backoff is the real reliability mechanism. |
| 7 | Watch role | **Phase 3a:** Watch via phone relay (current `WatchConnectivity` architecture, polished). **Phase 3b (deferred):** Watch independent BLE. watchOS `CBCentralManager` can't stay connected in background >30s without a `WKApplication` background task; Wear OS FGS on watch has ~10min Doze limit. Independent watch BLE requires companion phone relay anyway — cut to relay-first. |
| 8 | Challenge dispatch order | Simultaneous broadcast to all connected devices. First response wins. No daemon changes needed. |
| 9 | Ignored notification behavior | Daemon timeout → password fallback. App auto-dismisses the notification when the challenge nonce expires (using `expiryUnix`, not a hardcoded value). |
| 10 | Notification permission timing | Request at first launch. Add a pre-prompt explanation sheet before the system prompt to improve grant rate (denial rate ~60% without pre-prompt for auth products). |
| 11 | iOS notification handling | Main app — no Notification Service Extension. `bluetooth-central` keeps BLE alive in background; notification action foregrounds the app. |
| 12 | Implementation priority | Android first (biggest functional gap), then iOS polish, then Watch relay polish, then Watch independent BLE (deferred). |
| 13 | Android persistent notification | Minimal, low-priority, visible ("TouchBridge — Connected to MacBook Pro"). `setOngoing(true)` + `setForegroundServiceBehavior(FOREGROUND_SERVICE_IMMEDIATE)`. Separate high-priority channel for challenge notifications. If user disables the persistent channel, FGS is killed on Android 14+ — handle gracefully. |
| 14 | Android auto-start | Auto-start on boot if paired. `LOCKED_BOOT_COMPLETED` for Direct Boot support. BLE connects before unlock; biometric approval requires unlock. **Must use device-protected storage** for paired-Mac check (credential-protected storage is unreadable in Direct Boot). |

## Implementation Plan

### Phase 1: Android Foreground Service

**Goal:** Android companion can receive and respond to auth challenges while
backgrounded, with a persistent BLE connection and proper notifications.

**Fix order (from review):** Direct Boot storage → timeout semantics →
deferred challenge queue → POST_NOTIFICATIONS denial → silent biometric →
adaptive GATT.

**Scope:**

1. **`TouchBridgeService`** — a foreground service that owns the BLE client,
   ECDH session, and challenge handler. The ViewModel becomes a thin UI layer
   that observes the service state via a `LocalBinder` + `StateFlow`.

   - `foregroundServiceType="connectedDevice"` on Android 14+
   - `ServiceCompat.startForeground(NOTIF_ID, notif, FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)` within 5s of `onCreate` (Android 14 enforcement — or `ForegroundServiceStartNotAllowedException`)
   - Starts after pairing completes; stops on unpair
   - `android:directBootAware="true"` on service + `<application>`
   - Survives app being backgrounded or killed

2. **Direct Boot storage fix (must-fix before anything else):**
   - Current `TouchBridgeViewModel.kt:58` uses `Context.MODE_PRIVATE` (credential-protected)
   - `BootReceiver` running on `LOCKED_BOOT_COMPLETED` can't read credential-protected storage
   - Move `PREF_PAIRED_MAC_ID`, `PREF_PAIRED_MAC_NAME`, `PREF_DEVICE_ID` to
     `createDeviceProtectedStorageContext().getSharedPreferences(...)`
   - Or use `EncryptedSharedPreferences` with device-protected backing context
   - Without this fix, `BootReceiver` finds no paired Mac and does nothing

3. **Notification channels:**
   - `CHANNEL_PERSISTENT` (`IMPORTANCE_LOW`) — "TouchBridge is running" with
     connection status text. `setOngoing(true)` +
     `setForegroundServiceBehavior(FOREGROUND_SERVICE_IMMEDIATE)`. No sound,
     no vibration. Small status bar icon.
   - `CHANNEL_CHALLENGE` (`IMPORTANCE_HIGH`) — auth request notifications with
     sound, vibration, and "Approve" action button.
   - Check `NotificationManager.areNotificationsEnabled()` — if denied, UI must
     show blocking banner + deep-link to `Settings.ACTION_APP_NOTIFICATION_SETTINGS`

4. **`BootReceiver`** — `BroadcastReceiver` for `LOCKED_BOOT_COMPLETED`:
   - `android:exported="true"` (required for system broadcast)
   - `android:directBootAware="true"` on receiver
   - Reads paired-Mac ID from **device-protected storage** (not credential-protected)
   - If paired, starts `TouchBridgeService` in Direct Boot
   - BLE connection establishes before unlock; biometric prompt requires unlock

5. **Adaptive BLE keepalive:**
   - `requestConnectionPriority(CONNECTION_PRIORITY_LOW_POWER)` when idle — this
     is a **hint**, not a command. The Mac's `CBPeripheralManager` controls the
     actual interval. Don't rely on it for correctness, only battery.
   - `requestConnectionPriority(CONNECTION_PRIORITY_HIGH)` when a challenge is
     received (low latency for response transmission)
   - Reconnect on disconnect with exponential backoff (this is the real
     reliability mechanism, not connection priority)
   - Change idle scan mode from `SCAN_MODE_LOW_LATENCY` (current
     `BLEClient.kt:111`) to `SCAN_MODE_BALANCED` — `LOW_LATENCY` is too
     aggressive for background and will be throttled
   - `requestMtu(512)` already in `BLEClient.kt:328` — verify it survives the
     service migration

6. **Challenge notification with "Approve" action:**
   - `PendingIntent` with action `APPROVE_CHALLENGE`
   - Tapping "Approve" opens `MainActivity` with the challenge data
   - `BiometricPrompt` runs (requires activity — use `MainActivity` or a
     transparent activity)
   - On approval, sign and send response via the service's BLE client

7. **`POST_NOTIFICATIONS` permission (Android 13+) — handle denial:**
   - `MainActivity.kt` currently never requests it — must add
     `ActivityCompat.requestPermissions` flow
   - If denied: foreground service still connects and maintains BLE, but
     challenge notifications won't show. UI must show a blocking banner
     with a deep-link to `Settings.ACTION_APP_NOTIFICATION_SETTINGS`
   - Do not silently fall back to polling — surface the problem to the user

8. **OEM battery killer handling:**
   - Xiaomi/Samsung/OnePlus kill `connectedDevice` FGS unless user disables
     "battery optimization"
   - Consider `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt after pairing
     (Play policy sensitive — only request for apps that qualify, document
     the justification)
   - Document the manual step in the pairing success screen: "If TouchBridge
     stops working after a while, disable battery optimization for this app"

9. **Manifest changes:**
   - `<service android:name=".TouchBridgeService" android:foregroundServiceType="connectedDevice" android:directBootAware="true" />`
   - `<receiver android:name=".BootReceiver" android:exported="true" android:directBootAware="true">` with `LOCKED_BOOT_COMPLETED` intent filter
   - `<application android:directBootAware="true">` (enables Direct Boot for the whole app)
   - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />`
   - `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />`
   - `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />`
   - `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`
   - `<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />` (optional, Play policy sensitive)
   - Bump `compileSdk` to 34 (already `tools:targetApi="34"` in manifest)

**Files to create:**
- `companion/android/app/src/main/java/dev/touchbridge/android/service/TouchBridgeService.kt`
- `companion/android/app/src/main/java/dev/touchbridge/android/service/BootReceiver.kt`
- `companion/android/app/src/main/java/dev/touchbridge/android/service/NotificationHelper.kt`

**Files to modify:**
- `companion/android/app/src/main/AndroidManifest.xml` (service, receiver, permissions, Direct Boot)
- `companion/android/app/src/main/java/dev/touchbridge/android/ui/screens/TouchBridgeViewModel.kt` (delegate to service, Direct Boot storage)
- `companion/android/app/src/main/java/dev/touchbridge/android/core/BLEClient.kt` (lifecycle owned by service, scan mode change)
- `companion/android/app/src/main/java/dev/touchbridge/android/MainActivity.kt` (notification action intents, POST_NOTIFICATIONS request, battery optimization prompt)
- `companion/android/app/src/main/java/dev/touchbridge/android/ui/screens/HomeScreen.kt` (notification-denied banner, battery optimization prompt)

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
   - Set `content.interruptionLevel = .timeSensitive` on
     `UNMutableNotificationContent` (iOS 15+)
   - This is a content property, **not** a notification authorization option
   - The authorization request uses `[.alert, .sound, .badge]` — there is no
     `.timeSensitive` authorization option
   - Breaks through Focus modes / DND
   - No special entitlement needed

3. **`UNUserNotificationCenterDelegate`:**
   - Implement `userNotificationCenter(_:didReceive:withCompletionHandler:)`
   - Handle `APPROVE` action: run silent biometric check, sign, send response
   - Handle notification body tap: open `AuthRequestView` with challenge details
   - Implement `userNotificationCenter(_:willPresent:withCompletionHandler:)`
     for the foreground case — currently `CompanionCoordinator.swift:340` only
     handles background → notification. When the app is active, challenges
     should show inline (not post a notification).

4. **Silent biometric check (with fallback):**
   - When the app foregrounds via notification action, call
     `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`
   - **Not guaranteed silent:** if `context.biometryType == .faceID` and face
     not in frame, full overlay still shows. This is expected behavior.
   - `AuthRequestView` must be visible behind the biometric prompt as the
     fallback UI — don't present a blank window
   - If silent check passes: sign and respond immediately (fast path)
   - If silent check fails: show full Face ID prompt with `localizedReason`
   - If user cancels: send no response (daemon times out → password)
   - Track `succeedsWithoutUI` from `evaluatePolicy` result to decide whether
     to show a checkmark animation or a full prompt duration

5. **Auto-dismiss notification on nonce expiry:**
   - Use `expiryUnix` from `TBChallengeIssued` (10s nonce TTL), not a hardcoded
     15s (which is the PAM global timeout — different thing)
   - **In-app timers don't fire when the app is suspended** (background timers
     are killed by iOS). Two strategies:
     - **When app is active:** schedule a `Timer` or `Task.sleep` to remove the
       notification at `expiryUnix`
     - **When app is suspended:** on `didBecomeActive`, always call
       `UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:)`
       for any stale challenge IDs (not `removeAllDeliveredNotifications` which
       wipes unrelated notifications — current code at
       `CompanionCoordinator.swift:95` does `removeAll`, fix to per-ID removal)
   - Use `identifier = challengeID` (not a fixed string) so multiple challenges
     can be tracked independently

6. **Deferred challenge queue (fix single-slot race):**
   - Current `CompanionCoordinator.swift:42` stores `private var deferredChallenge: Data?`
     — one slot. If two `sudo` arrive while backgrounded, the second overwrites
     the first. The daemon's `pendingAuthentications` (keyed per-challenge)
     expects both to be handled.
   - Replace with a queue: `private var deferredChallenges: [(challengeID: String, data: Data)] = []`
   - On `didBecomeActive`: process the most recent challenge, remove all
     delivered notifications for older challenge IDs (they're stale)
   - Or: drop older challenges and `removeDeliveredNotifications` before posting
     a new one (simpler, matches "most recent wins" UX)

7. **Notification permission at first launch with pre-prompt:**
   - Add a brief explanation sheet before the system prompt: "TouchBridge needs
     notifications to alert you when your Mac needs approval."
   - Then request `[.alert, .sound, .badge]` (no `.timeSensitive` option exists)
   - Pre-prompt improves grant rate from ~40% to ~70% for auth products

8. **Background BLE scan throttling:**
   - `BLEClient.swift:128` uses `CBCentralManagerScanOptionAllowDuplicatesKey: true`
   - iOS throttles this to ~1/min in background — be aware that reconnection
     after background suspension may take up to 60s
   - Test on real device with screen off for 5min to verify reconnection
   - Consider dropping `AllowDuplicatesKey` in background (iOS ignores it
     anyway) to avoid log spam

**Files to modify:**
- `companion/ios/TouchBridge/App/AppDelegate.swift` (register notification category, fix authorization options, add pre-prompt)
- `companion/ios/TouchBridge/Core/CompanionCoordinator.swift` (notification category, action handling, silent biometric, auto-dismiss, deferred challenge queue, per-ID notification removal)
- `companion/ios/TouchBridge/Core/ChallengeHandler.swift` (silent biometric check path with fallback)
- `companion/ios/TouchBridge/Core/LocalAuthManager.swift` (add `succeedsWithoutUI` tracking)
- `companion/ios/TouchBridge/Views/AuthRequestView.swift` (ensure visible behind biometric prompt)
- `companion/ios/TouchBridge/Resources/Info.plist` (no changes needed — `bluetooth-central` already declared)

### Phase 3a: Watch via Phone Relay (Polish)

**Goal:** Polish the existing `WatchConnectivity` architecture so the watch
reliably receives challenges forwarded from the phone and can approve them.

**Scope:**

1. **Phone → Watch forwarding:**
   - When the phone receives a challenge (foreground or background), forward it
     to the watch via `WCSession.sendMessage` (if reachable) or
     `WCSession.transferUserInfo` (if not reachable, delivered when watch wakes)
   - Include challenge ID, reason, Mac name, user

2. **Watch approval UI:**
   - Watch shows approve/deny prompt with haptic notification
   - User taps approve (or double-clickes side button — match Apple Pay)
   - Watch sends approval back to phone via `WCSession.sendMessage`
   - Phone signs the nonce and sends response to Mac

3. **Watch does NOT do cryptography** — the phone's Secure Enclave signs.
   The watch is purely a remote approval UI.

**Files to modify:**
- `companion/ios/TouchBridgeWatch/App/WatchConnectivityManager.swift` (polish, haptics, background delivery)
- `companion/ios/TouchBridge/Core/CompanionCoordinator.swift` (forward challenges to watch)

### Phase 3b: Watch Independent BLE (Deferred)

**Goal:** Watch connects directly to the Mac over BLE with its own signing key.

**Why deferred:** watchOS `CBCentralManager` can't stay connected in background
>30s without a `WKApplication` background task. Wear OS FGS on watch has ~10min
Doze limit. Direct BLE watch → Mac will need companion phone relay anyway for
background reliability. The relay-first approach (Phase 3a) delivers 90% of the
value with 10% of the complexity.

**Scope (when implemented):**

1. Watch generates its own signing key in Secure Enclave / Android Keystore
2. Watch pairs with the Mac separately (or as part of phone pairing)
3. Watch does its own ECDH, identify, challenge response over direct BLE
4. Mac stores the watch's public key and deviceID in Keychain
5. Simultaneous broadcast — watch naturally wins (faster, no unlock needed)
6. Phone is fallback when watch is off-wrist or disconnected

**Files to create (when implemented):**
- `companion/ios/TouchBridgeWatch/Core/WatchBLEClient.swift`
- `companion/ios/TouchBridgeWatch/Core/WatchCoordinator.swift`
- `companion/ios/TouchBridgeWatch/Core/WatchSigningProvider.swift`
- `companion/android/wear/` — Wear OS BLE client and signing

## Security Considerations

- **Silent biometric check does not weaken security:** Face ID still runs — it
  just doesn't show a full UI overlay when the face was just detected. The
  biometric evaluation is the same; only the presentation differs. If the face
  is not in frame, the full overlay shows — this is a feature, not a bug.

- **No "Deny" button:** Intentional. Accidental denial in the pocket could lock
  the user out of their own sudo. Timeout → password fallback is the safe path.

- **`.timeSensitive` notifications:** Auth requests are genuinely urgent (blocking
  a terminal). Time-sensitive is the correct interruption level. The notification
  still respects the ringer switch — it won't blast sound on silent.

- **Android foreground service:** The persistent notification is the user's
  indicator that TouchBridge is running and consuming battery. The user can
  stop the service by unpairing or force-stopping the app. `setOngoing(true)`
  prevents accidental dismissal.

- **Watch independent signing key (Phase 3b):** The watch's signing key is
  separate from the phone's. Compromising one device doesn't compromise the
  other. The Mac stores both keys and can verify responses from either.

- **No relay server:** All communication is over BLE. No auth metadata is sent
  to any server. No APNs/FCM push notifications are used.

- **Direct Boot storage:** Moving pairing data to device-protected storage
  means it's readable before unlock. This is intentional (so BLE can connect
  before unlock) and safe — the pairing data is a Mac BLE service UUID and
  device ID, not a secret. The signing key is in Secure Enclave / Keystore,
  which is not accessible in Direct Boot — biometric approval requires unlock.

## Battery Impact

Values are estimates to be replaced with measurements:

| Platform | Idle | Active (challenge) |
|----------|------|--------------------|
| iOS | ~1-2%/day (bluetooth-central background mode) | ~0.1% per auth (BLE + Face ID + signing) |
| Android | ~2-3%/day (foreground service + low-power GATT) | ~0.2% per auth (BLE + biometric + signing) |
| Watch (relay) | Negligible (WatchConnectivity, no BLE) | ~0.05% per auth (haptic + UI) |
| Watch (independent, Phase 3b) | ~1-2%/day (BLE connected, wrist detection) | ~0.1% per auth (BLE + signing) |

**Measurement plan:**
- Android: `adb shell dumpsys batterystats` over 24h idle with FGS running
- iOS: Xcode Energy Organizer + `org.os_signpost` intervals for BLE wake events
- Watch: Xcode Energy Organizer for watchOS app

## Open Questions

- Should the Android foreground service show connection status in the persistent
  notification text ("Connected" / "Searching…" / "Disconnected")? (Recommended:
  yes, but implementation detail.)
- For the watch (Phase 3b), should wrist-raised be sufficient to approve, or
  should it require an explicit tap? (Apple Pay requires double-click side
  button; we should match that for security.)
- Should `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` be requested automatically after
  pairing, or documented as a manual step? (Play policy is sensitive about this
  permission — auto-prompting may trigger review.)
- Should the iOS pre-prompt explanation sheet be a full screen or a sheet?
  (Recommended: sheet, presented once on first launch before the system prompt.)
