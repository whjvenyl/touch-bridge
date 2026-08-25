# TouchBridge Architecture

## Component Overview

```
┌─────────────────────────────────────────────────────┐
│                    macOS                             │
│                                                      │
│  ┌──────────┐    Unix Socket    ┌───────────────┐   │
│  │ PAM      │ ───────────────→  │ touchbridged  │   │
│  │ Module   │                   │ (daemon)      │   │
│  └──────────┘                   │               │   │
│                                 │ ┌───────────┐ │   │
│  ┌──────────┐    Unix Socket    │ │ Socket    │ │   │
│  │ Auth     │ ───────────────→  │ │ Server    │ │   │
│  │ Plugin   │                   │ └───────────┘ │   │
│                                 │ ┌───────────┐ │   │
│                                 │ │ Challenge │ │   │
│                                 │ │ Manager   │ │   │
│                                 │ └───────────┘ │   │
│                                 │ ┌───────────┐ │   │
│                                 │ │ BLE       │ │   │
│                                 │ │ Server    │ │   │
│                                 │ └─────┬─────┘ │   │
│                                 └───────┼───────┘   │
│                                         │ BLE       │
└─────────────────────────────────────────┼───────────┘
                                          │
┌─────────────────────────────────────────┼───────────┐
│                  iPhone/iPad            │           │
│                                         │           │
│                                 ┌───────┴─────┐    │
│                                 │ BLE Client  │    │
│                                 └───────┬─────┘    │
│                                 ┌───────┴─────┐    │
│                                 │ Challenge   │    │
│                                 │ Handler     │    │
│                                 └───────┬─────┘    │
│                          ┌──────────────┼────────┐ │
│                          │              │        │ │
│                    ┌─────┴─────┐  ┌─────┴──────┐ │ │
│                    │ LAContext │  │ Secure     │ │ │
│                    │ (Face ID) │  │ Enclave    │ │ │
│                    └───────────┘  └────────────┘ │ │
│                                                    │
└────────────────────────────────────────────────────┘
```

## Data Flow: sudo authentication

1. User runs `sudo echo test`
2. PAM loads `pam_touchbridge.so`
3. PAM module connects to daemon socket (`~/Library/Application Support/TouchBridge/daemon.sock`)
4. SocketServer receives request, calls `DaemonCoordinator.authenticateFromPAM()`
5. DaemonCoordinator finds connected companion via BLE
6. ChallengeManager generates 32-byte nonce with 10s expiry
7. Nonce encrypted with AES-256-GCM (ECDH session key) and sent via BLE
8. CompanionCoordinator receives, decrypts, shows Face ID prompt
9. On success, SecureEnclaveManager signs nonce (ECDSA P-256)
10. Signature sent back via BLE
11. ChallengeManager verifies signature against pinned public key
12. Result returned through continuation → SocketServer → PAM module
13. PAM returns `PAM_SUCCESS` or `PAM_AUTH_ERR`

## Component Inventory

### macOS daemon (`mac/daemon/`)

| Component | Responsibility |
|-----------|---------------|
| ChallengeManager | 32-byte nonce via `SecRandomCopyBytes`, 10s expiry, replay protection (60s seen-nonces window), ECDSA P-256 verification |
| KeychainStore | Store/retrieve/list/remove paired device public keys in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) |
| SessionCrypto | ECDH P-256 ephemeral key agreement via CryptoKit, HKDF-SHA256 derivation, AES-256-GCM encrypt/decrypt for BLE channel |
| WireFormat | MessagePack-style encoding, 256-byte max message size, version byte header, JSON payload |
| AuditLog | Append-only NDJSON to `~/Library/Logs/TouchBridge/`, ISO 8601 timestamps, never logs nonce values |
| BLEServer | macOS GATT peripheral (`CBPeripheralManager`) with 4 characteristics: session key, challenge, response, pairing |
| SocketServer | Unix domain socket at `~/Library/Application Support/TouchBridge/daemon.sock`, POSIX sockets + DispatchSource |
| DaemonCoordinator | Central integration point; `authenticateFromPAM()` uses `CheckedContinuation` with task group timeout race |
| PolicyEngine | Reads `AuthTimeoutSeconds` from `policy.plist` (default 15s); per-action biometric_required vs proximity_session |
| ProximitySessionStore | Thread-safe TTL-based session management for proximity sessions |
| SimulatorAuthHandler | Runs full crypto pipeline locally with software P-256 keys (no BLE/phone needed) |

### PAM module (`mac/pam/`)

| Component | Responsibility |
|-----------|---------------|
| pam_touchbridge.c | C11 PAM module, universal binary (arm64 + x86_64). Connects to daemon socket, sends JSON, parses response. Socket path resolved via `getpwnam()` |

### iOS companion (`companion/ios/`)

| Component | Responsibility |
|-----------|---------------|
| BLEClient | iOS GATT central (`CBCentralManager`) with background restoration via `CBCentralManagerOptionRestoreIdentifierKey` |
| SecureEnclaveManager | P-256 key generation inside Secure Enclave, signing, public key export, `SigningProvider` protocol with `MockSigningProvider` |
| LocalAuthManager | `LAContext` biometric prompt wrapper with `@MainActor` enforcement |
| ChallengeHandler | iOS orchestration: decrypt challenge → prompt biometric → sign nonce → encrypt response → send via BLE |
| PairingManager | QR payload generation (16-byte random token, 5-min expiry), token validation, public key format checks |
| CompanionCoordinator | Central integration point wiring all iOS components |

## Auth Surface Compatibility

| Surface | Works? | Mechanism | Notes |
|---------|--------|-----------|-------|
| sudo (any terminal) | Yes | PAM module | Core feature |
| Screensaver unlock | Yes | PAM module | Core feature |
| App Store purchases | Yes | Authorization Plugin | Phase 3 |
| System Settings changes | Yes | Authorization Plugin | |
| Software install (.pkg) | Yes | Authorization Plugin | |
| Already-logged-in sessions | No | — | Session cookies, no auth event to intercept |
| Login screen (boot/wake) | No | — | Daemon needs user session (LaunchAgent) |
| FileVault unlock | No | — | Pre-boot, before OS loads |
| Apple Pay | No | — | Dedicated Secure Element hardware |
