#!/bin/bash
# build-all.sh — Build all macOS-side TouchBridge components.
#
# Builds: protocol, daemon, PAM module, menubar app.
# Does NOT build companion apps (they need Xcode/Android Studio).
#
# Usage:
#   bash scripts/build-all.sh           # debug build
#   bash scripts/build-all.sh release   # release build
#   bash scripts/build-all.sh test      # build + run tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_MODE="${1:-debug}"
RUN_TESTS=false

if [[ "$BUILD_MODE" == "test" ]]; then
  BUILD_MODE="debug"
  RUN_TESTS=true
fi

XCODE_CONFIG="Debug"
if [[ "$BUILD_MODE" == "release" ]]; then
  XCODE_CONFIG="Release"
fi

echo "━━━ TouchBridge Build ━━━"
echo "Mode: $BUILD_MODE${RUN_TESTS:+ (with tests)}"
echo ""

# 0. Generate protobuf code (if protoc is available)
if command -v protoc-gen-swift &>/dev/null; then
  echo "▸ Generating protobuf code…"
  bash "$PROJECT_DIR/protocol/generate.sh" 2>&1 | tail -1
  echo "  ✓ Protobuf"
  echo ""
else
  echo "▸ Skipping protobuf generation (install: brew install protobuf swift-protobuf)"
  echo "  Using existing generated files if present."
  echo ""
fi

# 1. Protocol package (SPM — cached after first build)
echo "▸ Building protocol package…"
cd "$PROJECT_DIR/protocol/swift"
swift build 2>&1 | tail -3
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing protocol package…"
  swift test 2>&1 | tail -3
fi
echo "  ✓ Protocol"
echo ""

# 2. Daemon + Menubar (single Xcode project)
echo "▸ Building macOS project (daemon + menubar)…"
cd "$PROJECT_DIR/mac"
xcodegen generate 2>&1 | tail -1
xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge -configuration "$XCODE_CONFIG" build 2>&1 | tail -3
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing daemon…"
  xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge -configuration Debug test 2>&1 | tail -3
fi
echo "  ✓ Daemon"
echo ""

# 3. PAM module
echo "▸ Building PAM module…"
make -C "$PROJECT_DIR/mac/pam" 2>&1 | tail -3
echo "  ✓ PAM module"
echo ""

# 4. Menubar app (bundled in the same Xcode project)
echo "▸ Building menubar app…"
xcodebuild -project TouchBridge.xcodeproj -scheme TouchBridgeMenu -configuration "$XCODE_CONFIG" build 2>&1 | tail -3
echo "  ✓ Menubar app"
echo ""

echo "━━━ Build Complete ━━━"
echo ""
echo "Built components:"
echo "  • Protocol:  protocol/swift/.build/"
echo "  • Daemon:    mac/ (DerivedData)"
echo "  • PAM:       mac/pam/pam_touchbridge.so"
echo "  • Menubar:   mac/ (DerivedData)"
echo ""
echo "To install: sudo bash scripts/install.sh"
