# TouchBridge — Architecture Review

**Date:** 2025-08-26 (revised)
**Scope:** Full codebase after protobuf migration, unified Xcode project, and Android protocol fixes

---

## Executive Summary

TouchBridge is a PAM-replacement system that delegates macOS authentication to a paired phone or watch via BLE. The cryptographic design is sound (ECDH + AES-GCM + ECDSA P-256 with Secure Enclave). The protocol is now defined as protobuf with cross-platform code generation. The iOS and Android companions are both protocol-compliant. The macOS daemon has 112 passing tests with proper thread safety.

**Most issues from the initial review have been fixed.** The remaining items are a partial identify-authentication gap, intentional stub files, and missing test coverage on companions.

| Area | Status |
|------|--------|
| Protocol & crypto design | Solid — protobuf single source of truth |
| macOS daemon | Functional, thread-safe, 112 tests |
| PAM module | Functional, JSON escaping fixed |
| iOS companion | Production-ready |
| Android companion | Protocol-compliant — all 5 critical issues fixed |
| Menubar control app | Functional, bundled with daemon + PAM + privileged helper |
| Browser extensions | Functional |
| Auth plugin | Stub — not production-ready |
| Documentation | AGENTS.md + Blume docs site |
| Test coverage | Good for daemon, none for companions |

---

## 1. What's Built and Working

### Protocol (`protocol/`)
- **Protobuf schema** (`protocol/proto/touchbridge.proto`) — single source of truth for all message types
- **Swift code generation** (`protocol/generate.sh`) — protoc → Swift, gitignored output
- **Android code generation** — protobuf Gradle plugin at build time
- **Wire format**: `[version:1][type:1][protobuf payload]`, 512-byte max
- **6 message types**: pairRequest, pairResponse, challengeIssued, challengeResponse, error, identify
- **Crypto**: ECDH P-256 → HKDF-SHA256 → AES-256-GCM session encryption, ECDSA P-256 signing

### macOS Daemon (`mac/daemon/`)
- **SocketServer** — Unix domain socket for PAM + control app. Actions: `authenticate`, `status`, `pair`, `cancelPairing`, `unpair`
- **DaemonCoordinator** — central orchestrator, implements `PAMAuthHandler` + `DaemonControlHandler`
- **ChallengeManager** — actor-based nonce issuance, ECDSA verification, replay protection (60s), expiry (10s)
- **PairingManager** — QR-based one-time pairing with 5-minute token expiry
- **KeychainStore** — paired device public key storage
- **BLEServer** — CoreBluetooth GATT peripheral, thread-safe (`centralsLock`, `pendingLock`)
- **PolicyEngine** — per-surface auth policy with configurable TTLs
- **SimulatorAuthHandler** — local testing without a phone
- **AuditLog** — NDJSON audit trail
- **Unified CLI** (`touchbridge`) — subcommands: serve, pair, challenge, list-devices, config, logs
- **112 unit/integration tests**

### PAM Module (`mac/pam/`)
- C universal binary (arm64 + x86_64)
- **JSON escaping fixed** — `json_escape()` function escapes quotes, backslashes, control chars
- Fail-open to password on any error

### Menubar Control App (`mac/menubar/`)
- Bundled in unified Xcode project with daemon + PAM + privileged helper
- **TouchBridgeHelper** — privileged daemon (SMAppService.daemon) for install/uninstall via XPC
- Real daemon status polling, QR pairing, multi-device management
- Auto-bundles daemon binary + PAM module into app Resources

### iOS Companion (`companion/ios/`)
- Full CoreBluetooth central with background restoration
- Secure Enclave ECDSA P-256 with biometric ACL
- Complete UI: pairing (QR scanner), auth request, settings, device list
- Watch app with approve/deny via WatchConnectivity

### Android Companion (`companion/android/`)
- **All 5 critical protocol issues fixed**:
  1. Protobuf raw bytes (no Base64) for encryptedNonce and signature
  2. Wire format headers (`[version][type]`) on all outgoing messages
  3. Identify message (type-6) sent after ECDH
  4. Pairing token included in pair request from QR payload
  5. Key invalidation error (type-5, code 1001) sent on biometric enrollment change
- StrongBox/TEE-backed Keystore with biometric requirement
- Wear OS app with challenge forwarding via Wearable Data Layer
- Protobuf Gradle plugin configured for build-time code generation

### Browser Extensions (`extensions/`)
- Chrome and Safari extensions with WebAuthn interception
- Native messaging host communication

---

## 2. What's Been Fixed (since initial review)

| Issue | Status | Evidence |
|-------|--------|----------|
| Android Base64 encoding mismatch | **Fixed** | ChallengeHandler.kt uses protobuf raw bytes |
| Android missing wire format headers | **Fixed** | WireFormat.kt implements `[version][type]` encoding |
| Android missing identify message | **Fixed** | TouchBridgeViewModel.kt sends type-6 after ECDH |
| Android missing pairing token | **Fixed** | PairingScreen.kt extracts token from QR, passes to pair request |
| Android missing key invalidation error | **Fixed** | MainActivity.kt sends error code 1001 on biometric change |
| Daemon threading (BLEServer, AuthNotifier, ProximityMonitor) | **Fixed** | All mutable state protected by NSLocks |
| PAM JSON injection | **Fixed** | `json_escape()` function in pam_touchbridge.c |
| Protocol defined in Swift only | **Fixed** | Protobuf schema with cross-platform code generation |
| 256-byte message limit | **Fixed** | Increased to 512 bytes |
| WebCompanion XSS / IP detection | **N/A** | WebCompanion removed entirely |
| `touchbridge-test` not installed | **N/A** | Replaced by unified `touchbridge` CLI |

---

## 3. Remaining Issues

### 🟡 Identify Message Not Cryptographically Authenticated

**Location:** `mac/daemon/Sources/TouchBridgeCore/DaemonCoordinator.swift`, `handleIdentify()` (line 539-570)

**Issue:** The identify message is now encrypted with the session key (ECDH-derived), but the daemon only checks whether the claimed `deviceID` exists in the keychain. It does not require a signature proving the device possesses the paired private key.

**Risk:** A device that completes ECDH (which is unauthenticated) could claim any known deviceID. In practice, an attacker would need to:
1. Be in BLE range
2. Complete ECDH (intercepting or establishing a connection)
3. Know a valid deviceID (which requires prior access to the Mac's keychain)

**Assessment:** Low-to-moderate risk. The ECDH encryption provides confidentiality, and the keychain check prevents unknown deviceIDs. But it's not proof-of-possession.

**Recommendation:** Add a signature to the identify message — sign a challenge or the session key with the device's paired private key. The daemon already has the public key in the keychain to verify against.

### 🟡 Dead Code Stubs (intentional)

Five files remain as empty stubs with comments indicating future Wi-Fi transport:
- `mac/daemon/Sources/TouchBridgeCore/TransportRouter.swift`
- `mac/daemon/Sources/TouchBridgeCore/WiFiTransport.swift`
- `mac/daemon/Sources/TouchBridgeCore/XPCServer.swift`
- `companion/ios/TouchBridge/Core/TransportClient.swift`
- `companion/ios/TouchBridge/Core/WiFiClient.swift`

**Assessment:** These are documented placeholders, not accidental dead code. They signal intent for future Wi-Fi transport. Acceptable to keep, but consider moving to a `future/` directory or tracking with issues if they cause confusion.

### 🟡 Auth Plugin Still a Stub

`mac/authplugin/` — `AuthUI.swift` is a logging placeholder. The plugin compiles but has no SecurityAgent UI integration. Requires Developer ID signing + notarization for production.

**Assessment:** This is a known future feature, not a regression. The PAM module covers `sudo` and screensaver. The auth plugin would add App Store and System Settings auth.

### 🟡 No Companion Test Coverage

- iOS companion: 0 tests
- Android companion: 0 tests
- No cross-platform protocol conformance tests

**Recommendation:** Add at least protocol conformance tests on each platform that verify wire format encoding/decoding matches the protobuf schema.

### 🟡 Unauthenticated ECDH Exchange

The initial ECDH key exchange is not authenticated — neither side signs their ephemeral public key with their paired device key. A sophisticated MITM could intercept and establish two separate ECDH sessions.

**Mitigation:** The challenge-response proves key possession after ECDH, so a MITM can't forge approvals. But they could observe traffic.

**Recommendation:** Sign ECDH public keys with paired device keys, or use BLE LE Secure Connections.

---

## 4. Conceptual Notes

### Multi-Mac Limitation on Phone Side

The iOS companion pairs with a single Mac at a time. Pairing with a second Mac replaces the first. The daemon supports multiple companions, but the phone doesn't support multiple Macs.

### No CI for Android/Wear OS

CI builds daemon, protocol, PAM, and iOS. No Android build or test in CI. Adding `./gradlew assembleDebug` to CI would catch build regressions.

---

## 5. Recommendations (Prioritized)

### P1 — Security
1. Add cryptographic signature to identify message (proof-of-possession)
2. Sign ECDH public keys with paired device keys (authenticate key exchange)
3. Add Android CI to catch build regressions

### P2 — Test Coverage
4. Add iOS companion tests (protocol conformance at minimum)
5. Add Android companion tests (protocol conformance at minimum)
6. Add cross-platform integration test (wire format compatibility)

### P3 — Features
7. Multi-Mac support on phone side
8. Auth plugin SecurityAgent UI implementation
9. Developer ID signing + notarization for distribution
10. Wi-Fi transport (if BLE range is insufficient)

### P4 — Cleanup
11. Decide whether to keep or remove Wi-Fi transport stubs
12. Document socket control protocol (status, pair, unpair actions) in the docs site
