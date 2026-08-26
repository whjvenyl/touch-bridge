---
title: Architecture Review
description: Comprehensive audit of what's built, broken, and needs work
---

# TouchBridge — Architecture Review

**Date:** 2026-08-26 (revised)
**Scope:** Full codebase after authenticated identify, device types/caps, selection policy, and kill-switch

---

## Executive Summary

TouchBridge is a PAM-replacement system that delegates macOS authentication to a paired phone or watch via BLE. The cryptographic design is sound (ECDH + AES-GCM + ECDSA P-256 with Secure Enclave, authenticated identify with proof-of-possession). The protocol is defined as protobuf with cross-platform code generation. The iOS and Android companions are both protocol-compliant. The macOS daemon has 131 passing tests with proper thread safety.

| Area | Status |
|------|--------|
| Protocol & crypto design | Solid — protobuf single source of truth, authenticated identify |
| macOS daemon | Functional, thread-safe, 131 tests |
| PAM module | Functional, JSON escaping fixed |
| iOS companion | Production-ready, sends signed identify + device type |
| Android companion | Protocol-compliant, sends signed identify + device type |
| Menubar control app | Functional, device enable/disable, link quality display |
| Browser extensions | Functional |
| Auth plugin | Stub — not production-ready |
| Documentation | AGENTS.md + Blume docs site |
| Test coverage | Good for daemon, golden vectors for protocol, basic Android tests |

---

## 1. What's Built and Working

### Protocol (`protocol/`)
- **Protobuf schema** (`protocol/proto/touchbridge.proto`) — single source of truth for all message types
- **Swift code generation** (`protocol/generate.sh`) — protoc → Swift, gitignored output
- **Android code generation** — protobuf Gradle plugin at build time
- **Wire format**: `[version:1][type:1][protobuf payload]`, 512-byte max
- **6 message types**: pairRequest, pairResponse, challengeIssued, challengeResponse, error, identify
- **Device types**: `PHONE`, `WATCH`, `RING`, `TABLET` with capability descriptors
- **Crypto**: ECDH P-256 → HKDF-SHA256 → AES-256-GCM session encryption, ECDSA P-256 signing
- **Authenticated identify**: `Identify.signature` proves possession of paired private key
- **Cross-platform golden vectors**: Shared JSON test vectors verify Swift ↔ Kotlin wire format compatibility

### macOS Daemon (`mac/daemon/`)
- **SocketServer** — Unix domain socket for PAM + control app. Actions: `authenticate`, `status`, `pair`, `cancelPairing`, `unpair`, `setDeviceEnabled`, `setDevicePriority`
- **DaemonCoordinator** — central orchestrator, implements `PAMAuthHandler` + `DaemonControlHandler`
- **ChallengeManager** — actor-based nonce issuance, ECDSA verification, replay protection (60s), expiry (10s)
- **PairingManager** — QR-based one-time pairing with 5-minute token expiry, stores device type + caps
- **KeychainStore** — paired device public key + device type + caps storage
- **DeviceRuntimeStore** — in-memory + `devices.json` (0o600) for enabled/priority/lastSeen/linkQuality
- **BLEServer** — CoreBluetooth GATT peripheral, thread-safe
- **PolicyEngine** — per-surface auth policy, selection policy (anyOneOf + priorityOrder), kill-switch
- **SimulatorAuthHandler** — local testing without a phone
- **AuditLog** — NDJSON audit trail
- **Kill-switch** — `TOUCHBRIDGE_FORCE_PASSWORD=1` env var or `ForcePasswordFallback` plist key forces password fallback
- **Watch delegation rule** — WATCH without secure enclave rejected from direct challenge response
- **Selection policy** — `anyOneOf` (default broadcast) + `priorityOrder` (sequential with per-device budget)
- **131 unit/integration tests**

### PAM Module (`mac/pam/`)
- C universal binary (arm64 + x86_64)
- **JSON escaping fixed** — `json_escape()` function escapes quotes, backslashes, control chars
- Fail-open to password on any error

### Menubar Control App (`mac/menubar/`)
- Bundled in unified Xcode project with daemon + PAM + privileged helper
- **TouchBridgeHelper** — privileged daemon (SMAppService.daemon) for install/uninstall via XPC
- Real daemon status polling, QR pairing, multi-device management
- **Per-device enable/disable toggle** with link quality display
- Auto-bundles daemon binary + PAM module into app Resources

### iOS Companion (`companion/ios/`)
- Full CoreBluetooth central with background restoration
- Secure Enclave ECDSA P-256 with biometric ACL
- **Signed identify** — signs `deviceID || daemonEphemeralPubKey` with long-term SE key
- **Device type + caps** — sends `PHONE` type with biometric/SEP/display capabilities
- Complete UI: pairing (QR scanner), auth request, settings, device list
- Watch app with approve/deny via WatchConnectivity

### Android Companion (`companion/android/`)
- **All 5 critical protocol issues fixed** (see history below)
- **Signed identify** — signs `deviceID || daemonEphemeralPubKey` with Keystore key
- **Device type + caps** — sends `PHONE` type with biometric/SEP/display capabilities
- StrongBox/TEE-backed Keystore (biometric enforced at app layer, not OS level)
- Wear OS app with challenge forwarding via Wearable Data Layer
- Protobuf Gradle plugin configured for build-time code generation
- **7 unit tests** including golden vector conformance

### Browser Extensions (`extensions/`)
- Chrome and Safari extensions with WebAuthn interception
- Native messaging host communication

---

## 2. What's Been Fixed (since initial review)

| Issue | Status | Evidence |
|-------|--------|----------|
| Identify not cryptographically authenticated | **Fixed** | `Identify.signature` = ECDSA(deviceID ‖ ephemeralPubKey), daemon verifies against pinned key |
| Device type/caps not in protocol | **Fixed** | `DeviceType` enum + `DeviceCapabilities` message in proto, stored in Keychain |
| No selection policy | **Fixed** | `anyOneOf` (default) + `priorityOrder` with per-device budget |
| No kill-switch for sudo lockout | **Fixed** | `TOUCHBRIDGE_FORCE_PASSWORD` env + `ForcePasswordFallback` plist |
| Runtime state in Keychain | **Fixed** | `DeviceRuntimeStore` (devices.json, 0o600) for enabled/priority/lastSeen |
| No coarse link quality | **Fixed** | `LinkQuality` enum (good/fair/poor/unknown) from RSSI buckets |
| Watch without SEP can sign directly | **Fixed** | Daemon rejects WATCH without `hasSecureEnclave` from direct ChallengeResponse |
| Dead code stubs | **Removed** | TransportRouter, WiFiTransport, XPCServer, TransportClient, WiFiClient deleted |
| Android Base64 encoding mismatch | **Fixed** | ChallengeHandler.kt uses protobuf raw bytes |
| Android missing wire format headers | **Fixed** | WireFormat.kt implements `[version][type]` encoding |
| Android missing identify message | **Fixed** | TouchBridgeViewModel.kt sends type-6 after ECDH with signature |
| Android missing pairing token | **Fixed** | PairingScreen.kt extracts token from QR, passes to pair request |
| Android missing key invalidation error | **Fixed** | MainActivity.kt sends error code 1001 on biometric change |
| Daemon threading | **Fixed** | All mutable state protected by NSLocks |
| PAM JSON injection | **Fixed** | `json_escape()` function in pam_touchbridge.c |
| Protocol defined in Swift only | **Fixed** | Protobuf schema with cross-platform code generation |
| 256-byte message limit | **Fixed** | Increased to 512 bytes |

---

## 3. Remaining Issues

### 🟡 Auth Plugin Still a Stub

`mac/authplugin/` — `AuthUI.swift` is a logging placeholder. The plugin compiles but has no SecurityAgent UI integration. Requires Developer ID signing + notarization for production.

**Assessment:** Known future feature. The PAM module covers `sudo` and screensaver.

### 🟡 No iOS Companion Test Coverage

- iOS companion: 0 tests
- Android companion: 7 tests (golden vectors + protocol conformance)
- Cross-platform golden vectors exist but iOS doesn't run them

**Recommendation:** Add iOS protocol conformance tests matching the Android golden vector tests.

### 🟡 Android DER Signature Encoding

Android's `SHA256withECDSA` produces DER-encoded signatures. The daemon's `SecKeyVerifySignature(.ecdsaSignatureMessageX962SHA256)` expects X9.63 raw format (r‖s, 64 bytes). This affects both challenge-response and identify signatures. Hasn't surfaced because Android hasn't been physically E2E tested.

**Fix:** Convert DER to raw r‖s on Android before sending. Documented in `touchbridge.proto` comment.

### 🟡 Unauthenticated ECDH Exchange

The initial ECDH key exchange is not authenticated — neither side signs their ephemeral public key. A MITM could intercept and establish two separate ECDH sessions.

**Mitigation:** The identify signature now binds the session to the paired key, and the challenge-response proves key possession. A MITM can't forge approvals.

**Recommendation:** Sign ECDH public keys with paired device keys as a future hardening step.

---

## 4. Conceptual Notes

### Multi-Mac Limitation on Phone Side

The iOS companion pairs with a single Mac at a time. Pairing with a second Mac replaces the first. The daemon supports multiple companions, but the phone doesn't support multiple Macs.

### No CI for Android/Wear OS

CI builds daemon, protocol, PAM, and iOS. No Android build or test in CI. Adding `./gradlew assembleDebug` to CI would catch build regressions.

---

## 5. Recommendations (Prioritized)

### P1 — Security
1. Fix Android DER → raw signature encoding before physical E2E test
2. Sign ECDH public keys with paired device keys (authenticate key exchange)
3. Add Android CI to catch build regressions

### P2 — Test Coverage
4. Add iOS companion tests (protocol conformance at minimum)
5. Add cross-platform integration test (wire format compatibility)
6. Add E2E physical test with real iPhone + Mac

### P3 — Features
7. Multi-Mac support on phone side
8. Auth plugin SecurityAgent UI implementation
9. Developer ID signing + notarization for distribution

### P4 — Cleanup
10. Document socket control protocol in the docs site
11. Add `priorityOrder` group configuration UI to menubar app
