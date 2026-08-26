# TouchBridge — Developer Guide

## Prerequisites

```bash
# Required for building macOS/iOS components
xcode-select --install

# Required for protocol code generation (after cloning or when .proto changes)
brew install protobuf swift-protobuf

# Required for Xcode project generation
brew install xcodegen
```

## First-time setup

```bash
# Generate protobuf Swift code (required before any build)
bash protocol/generate.sh
```

The generated `touchbridge.pb.swift` is gitignored. It must exist before the
protocol SPM package can compile. `build-all.sh` runs this automatically, but
if you open the Xcode project directly you need to run it once after cloning.

## Build

```bash
# Build all macOS components (protocol, daemon, PAM, menubar)
bash scripts/build-all.sh

# Release build
bash scripts/build-all.sh release

# Build + run tests
bash scripts/build-all.sh test

# Individual components:
cd protocol/swift && swift build                          # protocol only
cd mac && xcodegen generate && xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge build       # daemon
cd mac && xcodegen generate && xcodebuild -project TouchBridge.xcodeproj -scheme TouchBridgeMenu build   # menubar (auto-bundles daemon + PAM)
make -C mac/pam                                           # PAM module only
```

## Test

```bash
# Protocol tests (fast, SPM)
cd protocol/swift && swift test

# Daemon tests (Xcode)
cd mac && xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge test

# Run specific test suite
cd mac && xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge test -only-testing:TouchBridgeCoreTests/ChallengeManagerTests
```

## Install / Uninstall

```bash
# CLI install (builds everything, patches PAM, installs LaunchAgent)
sudo bash scripts/install.sh

# CLI uninstall (restores PAM files, removes daemon)
sudo bash scripts/uninstall.sh

# Menu bar app: build and run from Xcode
# The app bundles daemon + PAM + privileged helper (SMAppService.daemon)
# Install/uninstall is handled in-app via XPC to the privileged helper
```

## Release

```bash
# Build release artifacts (CLI .pkg + menubar app .dmg)
bash scripts/build-release.sh
# Artifacts in dist/:
#   touchbridge-$VERSION.pkg  — CLI installer (brew cask)
#   TouchBridge-$VERSION.dmg  — Menu bar app (direct download)
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
  - `Sources/TouchBridgeProtocol/` — hand-written + generated protobuf code
  - `Generated/` — protoc output (gitignored, run `bash protocol/generate.sh`)
- `protocol/proto/` — canonical `.proto` schema
- `protocol/generate.sh` — generates Swift protobuf code (requires brew protobuf + swift-protobuf)
- `mac/` — unified Xcode project (xcodegen)
  - `project.yml` — root spec (options, packages, settings, schemes, includes)
  - `daemon/targets.yml` — daemon targets (TouchBridgeCore, touchbridge, tests)
  - `menubar/targets.yml` — menubar targets (TouchBridgeMenu, TouchBridgeHelper)
  - `daemon/Sources/TouchBridgeCore/` — testable library (ChallengeManager, KeychainStore, BLE, SocketServer, etc.)
  - `daemon/Sources/touchbridge/` — unified CLI (serve, pair, logs, config, list-devices, challenge)
  - `menubar/TouchBridgeMenu/` — menu bar app (status, pairing, settings, install/uninstall)
  - `menubar/TouchBridgeHelper/` — privileged helper daemon (SMAppService.daemon, XPC, root)
  - `pam/` — PAM module (C, universal binary arm64+x86_64)
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
