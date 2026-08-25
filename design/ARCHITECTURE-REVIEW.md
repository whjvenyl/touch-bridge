# TouchBridge — Architecture Review

**Date:** 2025-08-25
**Reviewer:** Devin (automated audit + manual analysis)
**Scope:** Full codebase after restructure (`mac/`, `companion/`, `extensions/`, `pam/`, `scripts/`)

---

## Executive Summary

TouchBridge is a well-conceived PAM-replacement system that delegates macOS authentication to a paired phone or watch via BLE. The cryptographic design is sound (ECDH + AES-GCM + ECDSA P-256 with Secure Enclave). The iOS companion is production-ready. The macOS daemon is functional with 112 passing tests.

**However, the Android companion has critical protocol incompatibilities that prevent it from working with the daemon.** The auth plugin is a stub. Several threading and error-handling issues exist in the daemon. Dead code stubs inflate the codebase.

| Area | Status |
|------|--------|
| Protocol & crypto design | Solid |
| macOS daemon | Functional, needs hardening |
| PAM module | Functional, needs JSON escaping |
| iOS companion | Production-ready |
| Android companion | **Broken — 5 critical protocol mismatches** |
| Menubar control app | Newly built, functional |
| Browser extensions | Functional, minor issues |
| Auth plugin | Stub — not production-ready |
| Documentation | Comprehensive but scattered |
| Test coverage | Good for daemon (112 tests), none for companions |

---

## 1. What's Built and Working

### macOS Daemon (`mac/daemon/`)
- **SocketServer** — Unix domain socket for PAM + control app communication. Supports `authenticate`, `status`, `pair`, `cancelPairing`, `unpair` actions.
- **DaemonCoordinator** — Central orchestrator wiring BLE, challenge management, pairing, session crypto, audit logging. Implements both `PAMAuthHandler` and `DaemonControlHandler`.
- **ChallengeManager** — Actor-based nonce issuance, ECDSA verification, replay protection (60s window), expiry (10s).
- **PairingManager** — QR-based one-time pairing ceremony with 5-minute token expiry.
- **KeychainStore** — Paired device public key storage in macOS Keychain.
- **BLEServer** — CoreBluetooth GATT peripheral with 4 characteristics (session key, challenge, response, pairing).
- **PolicyEngine** — Per-surface auth policy (biometric required vs proximity session) with configurable TTLs.
- **WebCompanion** — HTTP server for browser-based auth (testing convenience).
- **SimulatorAuthHandler** — Local software-key simulation for testing without a phone.
- **AuditLog** — NDJSON audit trail in `~/Library/Logs/TouchBridge/`.
- **112 unit/integration tests** — covering challenge lifecycle, ECDH, pairing, PAM integration, multi-device, replay, timeout, proximity.

### PAM Module (`mac/pam/`)
- C universal binary (arm64 + x86_64)
- Connects to daemon socket, sends JSON auth request, parses response
- Fail-open to password on any error (daemon down, timeout, denied)
- User-facing messages via PAM conversation

### iOS Companion (`companion/ios/`)
- **BLEClient** — Full CoreBluetooth central with background restoration
- **SecureEnclaveManager** — ECDSA P-256 in SE with biometric ACL
- **ChallengeHandler** — Decrypt, biometric prompt, sign, respond
- **CompanionCoordinator** — ECDH, identify, pairing, background challenges
- **WatchRelay** — WCSession forwarding to Apple Watch
- **UI** — Complete: pairing (QR scanner), home, auth request, settings, device list
- **Watch app** — Approve/deny UI via WatchConnectivity

### Menubar Control App (`mac/menubar/`)
- Real daemon status polling (paired devices, connections, advertising)
- Start/stop daemon, autolaunch toggle
- QR code pairing window
- Multi-device list with unpair
- Audit log activity feed
- Setup wizard

### Browser Extensions (`extensions/`)
- Chrome and Safari extensions
- Password field detection with TouchBridge banner
- WebAuthn interception
- Native messaging host communication

### Protocol (`protocol/swift/`)
- Wire format: `[version:1][type:1][JSON payload]`
- 6 message types: pairRequest, pairResponse, challengeIssued, challengeResponse, error, identify
- ECDH P-256 → HKDF-SHA256 → AES-256-GCM session encryption
- ECDSA P-256 signing with Secure Enclave / Android Keystore
- 256-byte max message size

---

## 2. What's Broken

### 🔴 Critical: Android Protocol Incompatibilities

The Android companion (`companion/android/`) has **5 critical mismatches** that prevent it from interoperating with the daemon:

| # | Issue | Impact |
|---|-------|--------|
| 1 | **Base64 encoding of binary fields** — Android encodes `encryptedNonce` and `signature` as Base64 strings in JSON; daemon/iOS use raw binary Data via CryptoKit's JSON encoder | Daemon cannot decrypt challenges or verify signatures from Android |
| 2 | **Missing wire format headers** — Android doesn't prepend `[version][type]` bytes to messages | Daemon rejects all Android messages as invalid wire format |
| 3 | **Missing identify message** — Android doesn't send type-6 identify after ECDH reconnection | Android must re-pair every time it reconnects (daemon won't recognize it) |
| 4 | **Missing pairing token** — Android's pair request doesn't include the `pairingToken` from the QR payload | Daemon rejects pairing (token validation fails) |
| 5 | **Missing key invalidation error** — Android doesn't send type-5 error when biometric enrollment changes | Daemon hangs on challenge instead of getting a clean failure |

**Root cause:** The Android app was built by mirroring the iOS app's structure but without matching the exact wire protocol. The protocol package (`protocol/swift/`) is Swift-only — there's no shared protocol definition for Kotlin.

**Fix path:** Either (a) fix the 5 issues in the Android code, or (b) generate a protocol schema (JSON Schema / protobuf) from `protocol/swift/` and share it across platforms.

### 🔴 Critical: Auth Plugin is a Stub

`mac/authplugin/` is a placeholder. `AuthUI.swift` is explicitly a logging stub. The plugin compiles but has no SecurityAgent UI integration. It also requires Developer ID signing + notarization for production use, which isn't set up.

### 🟡 Moderate: Daemon Threading Issues

| File | Issue |
|------|-------|
| `BLEServer.swift:108` | `connectedCentrals` dict accessed from multiple threads without synchronization — race condition |
| `AuthNotifier.swift:11` | `@unchecked Sendable` with mutable `isEnabled` — not thread-safe |
| `ProximityMonitor.swift:11` | `@unchecked Sendable` with mutable state — not thread-safe |
| `DaemonCoordinator.swift:25` | Non-recursive `NSLock` — potential deadlock if callbacks re-enter |
| `WebCompanion.swift:33` | Non-recursive `NSLock` — potential deadlock |

### 🟡 Moderate: PAM Module JSON Injection

`pam/pam_touchbridge.c:207` — username and service are interpolated into JSON via `snprintf` without escaping. If a username contains `"`, `\`, or control characters, the JSON breaks. In practice macOS usernames are restricted, but this is a defense-in-depth gap.

### 🟡 Moderate: WebCompanion Issues

- `getLocalIPAddress()` only checks `en0`/`en1` — fails on Macs with Wi-Fi on other interfaces
- Incomplete HTML escaping (missing single-quote escape) — XSS risk if device names contain quotes
- Expiry timer fires after continuation resumed — wasted work

---

## 3. What's Plain Wrong (Conceptual)

### Protocol Defined in Swift Only

The protocol package (`protocol/swift/`) defines message types, wire format, and constants in Swift. The iOS companion mirrors these manually in `Constants.swift` (with a comment saying "Mirrors protocol/Sources/..."). The Android companion mirrors them in `Constants.kt`.

**Problem:** No single source of truth. Constants can drift. The Android Base64 mismatch is a direct consequence — the Android developer didn't know the Swift JSON encoder handles `Data` as raw bytes, not Base64.

**Recommendation:** Extract a language-agnostic protocol schema (JSON Schema, protobuf, or even a shared constants file). Generate platform-specific bindings from it.

### 256-Byte Message Limit with JSON Encoding

The protocol uses JSON for payload encoding with a 256-byte max message size. Base64-encoded public keys (65 bytes → ~88 chars Base64) plus JSON overhead can approach this limit. The protocol doc mentions a planned migration to MessagePack but it hasn't happened.

**Problem:** Large payloads (e.g., pairing with long device names) may silently fail or truncate.

**Recommendation:** Either migrate to MessagePack (more compact) or increase the limit to 512 bytes. Add a fragmentation protocol if messages can exceed the limit.

### Identify Message Sent Before Authentication

The identify message (type 6) is sent after ECDH but the deviceID claim is not authenticated — any device that completes ECDH can claim any deviceID. The daemon checks the keychain for the claimed deviceID, but a MITM could observe a legitimate identify and replay it.

**Problem:** Device identity spoofing on reconnect.

**Recommendation:** Include a signature in the identify message proving possession of the paired private key.

### No Transport-Layer Authentication

BLE pairing (the QR ceremony) establishes a shared trust anchor (the device's public key). But the BLE connection itself uses default security (no LE Secure Pairing). A sophisticated attacker could MITM the BLE connection.

**Mitigation:** The ECDH session key provides encryption, and the challenge-response proves key possession. But the initial ECDH exchange is unauthenticated — an attacker could intercept and establish two separate ECDH sessions.

**Recommendation:** Use BLE LE Secure Connections (authenticated pairing) or sign the ECDH public keys with the paired device key.

### Multi-Mac Limitation on Phone Side

The iOS companion pairs with a single Mac at a time. Pairing with a second Mac replaces the first. The daemon supports multiple companion devices, but the phone doesn't support multiple Macs.

**Problem:** Users with multiple Macs must re-pair each time they switch.

**Recommendation:** Store multiple Mac pairings on the phone side, keyed by Mac identifier.

---

## 4. Dead Code

| File | Status |
|------|--------|
| `mac/daemon/Sources/TouchBridgeCore/TransportRouter.swift` | Empty stub — 4 lines, comment only |
| `mac/daemon/Sources/TouchBridgeCore/WiFiTransport.swift` | Empty stub — 5 lines, comment only |
| `mac/daemon/Sources/TouchBridgeCore/XPCServer.swift` | Empty stub — 5 lines, comment only |
| `companion/ios/TouchBridge/Core/TransportClient.swift` | Empty stub — 4 lines, comment only |
| `companion/ios/TouchBridge/Core/WiFiClient.swift` | Empty stub — 5 lines, comment only |
| `docs/index.html` + `docs/site/index.html` | Duplicate files |

**Recommendation:** Remove all stubs. If Wi-Fi transport is planned, create an issue and implement when ready — don't leave empty files.

---

## 5. Missing Infrastructure

### No Companion Tests
- iOS companion: 0 tests
- Android companion: 0 tests
- No integration tests that verify wire format compatibility between platforms

### No CI for Android/Wear OS
- CI builds daemon, protocol, PAM, and iOS
- No Android build or test in CI

### No API Documentation
- Socket protocol (request/response JSON format) is not documented
- Native messaging host format is not documented
- Wire format is documented in `protocol/swift/touchbridge-protocol.md` but not the control actions we just added

### No Code Signing for Distribution
- PAM module is ad-hoc signed (we just added this)
- Menubar app is ad-hoc signed
- No Developer ID / notarization setup
- Auth plugin requires Developer ID (not set up)

---

## 6. Security Assessment

### Strengths
- Private keys never leave Secure Enclave / Android Keystore
- Nonce freshness enforced (10s expiry + 60s replay window)
- Fail-open to password (never locks user out)
- Daemon runs as user, not root
- ECDH per-session encryption (AES-256-GCM)
- ECDSA P-256 signature verification against pinned keys
- Pairing is explicit and one-time (QR ceremony with token)

### Weaknesses
- PAM JSON injection (username not escaped)
- WebCompanion XSS (incomplete HTML escaping)
- Unauthenticated identify message (deviceID spoofing)
- Unauthenticated ECDH exchange (MITM possible on initial connection)
- Socket permissions may not be set correctly (chmod error ignored)
- `connectedCentrals` race condition could allow unauthorized connections

---

## 7. Recommendations (Prioritized)

### P0 — Fix Android (blocking)
1. Fix Base64 encoding mismatch in `ChallengeHandler.kt`
2. Add wire format headers to all outgoing messages
3. Implement identify message after ECDH
4. Add pairing token to pair request
5. Add key invalidation error handling

### P1 — Security Hardening
6. Escape username/service in PAM module JSON
7. Fix WebCompanion HTML escaping
8. Authenticate identify message with device key signature
9. Fix `connectedCentrals` threading in BLEServer
10. Fix `@unchecked Sendable` in AuthNotifier and ProximityMonitor

### P2 — Architecture
11. Extract protocol schema as language-agnostic (shared source of truth)
12. Remove dead code stubs
13. Add companion test coverage
14. Add Android CI
15. Document socket protocol and control actions

### P3 — Features
16. Multi-Mac support on phone side
17. Wi-Fi transport (if BLE range is insufficient)
18. Auth plugin SecurityAgent UI implementation
19. MessagePack migration (if 256-byte limit is hit)
20. Developer ID signing + notarization for distribution
