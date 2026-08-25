# TouchBridge — Developer Guide

## Build

```bash
# Build all macOS components (protocol, daemon, PAM, menubar)
bash scripts/build-all.sh

# Release build
bash scripts/build-all.sh release

# Build + run tests
bash scripts/build-all.sh test

# Individual components:
cd protocol/swift && swift build    # protocol only
cd mac/daemon && swift build         # daemon only
make -C mac/pam                      # PAM module only
cd mac/menubar && xcodegen generate && xcodebuild -project TouchBridgeMenu.xcodeproj build  # menubar (auto-bundles daemon + PAM module)
```

## Test

```bash
# Run all daemon tests
cd mac/daemon && swift test

# Run specific test suite
cd mac/daemon && swift test --filter ChallengeManager
cd mac/daemon && swift test --filter Keychain
cd mac/daemon && swift test --filter SocketServer
cd mac/daemon && swift test --filter PolicyEngine
cd mac/daemon && swift test --filter PAMIntegration
```

## Install / Uninstall

```bash
# Install (builds everything, patches PAM, installs LaunchAgent)
sudo bash scripts/install.sh

# Uninstall (restores PAM files, removes daemon)
sudo bash scripts/uninstall.sh
```

## E2E Test Flow

```bash
# 1. Install
sudo bash scripts/install.sh

# 2. Pair with iPhone
touchbridge pair

# 3. Open TouchBridge app on iPhone, enter pairing data

# 4. Test sudo
sudo echo 'TouchBridge works!'
# → Face ID prompt appears on iPhone
# → Approve → sudo succeeds
# → Deny/timeout → falls through to password
```

## Project Structure

- `protocol/swift/` — shared Swift Package (message types, wire format, constants)
- `mac/daemon/` — Swift Package, macOS LaunchAgent daemon
  - `Sources/TouchBridgeCore/` — testable library (ChallengeManager, KeychainStore, BLE, SocketServer, etc.)
  - `Sources/touchbridge/` — unified CLI (serve, pair, logs, config, list-devices, challenge)
- `mac/pam/` — PAM module (C, universal binary arm64+x86_64)
- `mac/menubar/` — SwiftUI menu bar control app (status, pairing, settings)
- `mac/authplugin/` — Swift auth plugin (stub)
- `companion/ios/` — iOS/iPadOS companion app (SwiftUI)
  - `TouchBridge/Core/` — CompanionCoordinator, BLEClient, SecureEnclaveManager, ChallengeHandler
  - `TouchBridge/Views/` — PairingView, AuthRequestView, DeviceListView, SettingsView
  - `TouchBridgeWatch/` — watchOS companion target
- `companion/android/` — Android + Wear OS companion app (Kotlin)
- `docs/` — Blume documentation site
- `design/` — architecture review, security model, limitations
- `scripts/` — build-all, install, uninstall, docs, release, e2e-validation, homebrew formula
- `marketing/` — assets, video, launch playbooks

## Key Rules

- Private keys NEVER leave Secure Enclave
- Never log nonce values — only session_id and result
- No hardcoded secrets, keys, UUIDs, or passwords in source
- Daemon runs as LaunchAgent (user-level), not root
- Ask before touching `/etc/pam.d/` — install script backs up and prompts
