---
title: TouchBridge Architecture
description: TouchBridge Architecture
---

# TouchBridge Architecture

## Component Overview

```
┌─────────────────────────────────────────────────────┐
│                    macOS                             │
│                                                      │
│  ┌──────────┐    Unix Socket    ┌───────────────┐   │
│  │ PAM      │ ───────────────→  │ touchbridge   │   │
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
