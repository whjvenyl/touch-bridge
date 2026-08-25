# Folder Structure Recommendation

## Current Structure (after restructure)

```
UnTouchID/
├── mac/              # macOS host code
│   ├── daemon/       # SwiftPM daemon
│   ├── protocol/     # SwiftPM protocol package
│   ├── pam/          # C PAM module
│   ├── menubar/      # SwiftUI control app
│   └── authplugin/   # Swift auth plugin (stub)
├── companion/        # Companion apps
│   ├── ios/          # iOS + watchOS (Xcode)
│   └── android/      # Android + Wear OS (Gradle)
├── extensions/       # Browser extensions
├── scripts/          # Install/build scripts
├── installer/        # Release packaging
├── docs/             # User docs
├── design/           # Architecture docs
├── marketing/        # Assets, video, launch
├── tools/            # Dev utilities
├── tests/            # E2E tests
└── homebrew/         # Homebrew formula
```

## Evaluation

### What works
- **`mac/` grouping** — all macOS host code in one place. Build commands are `cd mac/daemon && swift build`, `make -C mac/pam`. Clean.
- **`companion/ios` + `companion/android`** — companion apps grouped by platform. Clear.
- **`design/`** — architecture docs separated from user docs.

### What doesn't work
- **`protocol/swift/`** — the protocol package is conceptually shared across ALL platforms (daemon, iOS, Android), but it lives under `mac/` and is Swift-only. The Android companion can't use it. This is the root cause of the Android protocol mismatch.
- **No shared protocol definition** — each platform manually mirrors constants. There's no single source of truth.
- **`docs/` vs `design/`** — user-facing docs and architecture docs are split. With Blume, they should be unified.

## Recommendation: Keep current structure, add `protocol/` at root

The current structure is good. The one change I recommend:

```
UnTouchID/
├── protocol/         # ← MOVED: language-agnostic protocol definition
│   ├── swift/        # SwiftPM package (was protocol/swift/)
│   ├── schema.json   # JSON Schema for all message types (NEW)
│   └── constants.json # Shared constants (NEW)
├── mac/              # macOS host code (no longer contains protocol)
│   ├── daemon/
│   ├── pam/
│   ├── menubar/
│   └── authplugin/
├── companion/
│   ├── ios/
│   └── android/
├── extensions/
├── docs/             # Blume docs site (user + architecture)
├── design/           # Architecture review, ADRs
├── scripts/
├── installer/
├── marketing/
├── tools/
├── tests/
└── homebrew/
```

### Why not a full monorepo packages structure?

A monorepo with `packages/` (like `packages/daemon`, `packages/protocol`, `packages/pam`, etc.) would be over-engineering for this project:

1. **Different build systems** — SwiftPM, Xcode, Gradle, Make, npm. A monorepo package manager (Turborepo, Nx, Bazel) can't unify these.
2. **No cross-package dependencies** — the daemon depends on the protocol package, but the Android app doesn't depend on any Swift package. Each platform builds independently.
3. **Small team** — monorepo tooling overhead isn't justified for a project this size.

### Why move `protocol/` to root?

The protocol is the **contract between all platforms**. It shouldn't live under `mac/` — that implies it's macOS-specific. Moving it to root:

1. Signals that it's shared across platforms
2. Makes it natural to add a `protocol/schema.json` that Android can consume
3. The daemon's `Package.swift` changes from `.package(path: "../protocol")` to `.package(path: "../../protocol")` — trivial

### What about the Blume docs?

Move `docs/` content into a Blume docs site structure. The `design/` directory stays for architecture docs and ADRs. Blume can serve both user docs and architecture docs with different navigation sections.

## Action plan

1. Move `protocol/swift/` → `protocol/swift/`
2. Update daemon `Package.swift` path
3. Create `protocol/schema.json` (JSON Schema for message types)
4. Create `protocol/constants.json` (shared constants)
5. Update all path references
