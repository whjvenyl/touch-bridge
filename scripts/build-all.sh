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

SWIFT_BUILD_FLAGS=""
if [[ "$BUILD_MODE" == "release" ]]; then
  SWIFT_BUILD_FLAGS="-c release"
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

# 1. Protocol package
echo "▸ Building protocol package…"
cd "$PROJECT_DIR/protocol/swift"
swift build $SWIFT_BUILD_FLAGS 2>&1 | tail -3
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing protocol package…"
  swift test 2>&1 | tail -3
fi
echo "  ✓ Protocol"
echo ""

# 2. Daemon
echo "▸ Building daemon…"
cd "$PROJECT_DIR/mac/daemon"
swift build $SWIFT_BUILD_FLAGS 2>&1 | tail -3
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing daemon…"
  swift test 2>&1 | tail -3
fi
echo "  ✓ Daemon"
echo ""

# 3. PAM module
echo "▸ Building PAM module…"
make -C "$PROJECT_DIR/mac/pam" 2>&1 | tail -3
echo "  ✓ PAM module"
echo ""

# 4. Menubar app (if xcodegen is available)
if command -v xcodegen &>/dev/null; then
  echo "▸ Building menubar app…"
  cd "$PROJECT_DIR/mac/menubar"
  xcodegen generate 2>&1 | tail -1
  if [[ "$BUILD_MODE" == "release" ]]; then
    xcodebuild -project TouchBridgeMenu.xcodeproj -scheme TouchBridgeMenu -configuration Release build 2>&1 | tail -3
  else
    xcodebuild -project TouchBridgeMenu.xcodeproj -scheme TouchBridgeMenu -configuration Debug build 2>&1 | tail -3
  fi
  echo "  ✓ Menubar app"
  echo ""
else
  echo "▸ Skipping menubar app (xcodegen not installed)"
  echo "  Install with: brew install xcodegen"
  echo ""
fi

echo "━━━ Build Complete ━━━"
echo ""
echo "Built components:"
echo "  • Protocol:  protocol/swift/.build/${BUILD_MODE}/"
echo "  • Daemon:    mac/daemon/.build/${BUILD_MODE}/touchbridge"
echo "  • CLI:       mac/daemon/.build/${BUILD_MODE}/touchbridge (serve, pair, logs, config)"
echo "  • PAM:       mac/pam/pam_touchbridge.so"
if command -v xcodegen &>/dev/null; then
  echo "  • Menubar:   mac/menubar/build/ (or DerivedData)"
fi
echo ""
echo "To install: sudo bash scripts/install.sh"
