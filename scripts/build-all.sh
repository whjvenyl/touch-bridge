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

# Local build output directory (gitignored)
BUILD_DIR="$PROJECT_DIR/build"
mkdir -p "$BUILD_DIR"

echo "━━━ TouchBridge Build ━━━"
echo "Mode: $BUILD_MODE${RUN_TESTS:+ (with tests)}"
echo "Output: $BUILD_DIR/"
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

# 1. Protocol tests (fast — run via SPM, no Xcode needed)
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing protocol package…"
  cd "$PROJECT_DIR/protocol/swift"
  swift test 2>&1 | tail -3
  echo "  ✓ Protocol tests"
  echo ""
fi

# 2. Daemon + Menubar (single Xcode project — builds protocol SPM package as dependency)
echo "▸ Building macOS project (daemon + menubar)…"
cd "$PROJECT_DIR/mac"
xcodegen generate 2>&1 | tail -1

# Use a temp dir for DerivedData so it doesn't clutter the project
DERIVED_DATA="$(mktemp -d -t touchbridge-derived)"
trap 'rm -rf "$DERIVED_DATA"' EXIT
xcodebuild -project TouchBridge.xcodeproj \
  -scheme touchbridge \
  -configuration "$XCODE_CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  build 2>&1 | tail -3
if [[ "$RUN_TESTS" == true ]]; then
  echo "▸ Testing daemon…"
  xcodebuild -project TouchBridge.xcodeproj \
    -scheme touchbridge \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    test 2>&1 | tail -3
fi

# Copy daemon binary to build/
DAEMON_BIN="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/touchbridge"
if [[ -f "$DAEMON_BIN" ]]; then
  cp "$DAEMON_BIN" "$BUILD_DIR/touchbridge"
  chmod 755 "$BUILD_DIR/touchbridge"
  echo "  ✓ Daemon → $BUILD_DIR/touchbridge"
else
  echo "  ✗ Daemon binary not found at $DAEMON_BIN"
  exit 1
fi
echo ""

# 3. PAM module
echo "▸ Building PAM module…"
make -C "$PROJECT_DIR/mac/pam" 2>&1 | tail -3
cp "$PROJECT_DIR/mac/pam/pam_touchbridge.so" "$BUILD_DIR/pam_touchbridge.so"
echo "  ✓ PAM module → $BUILD_DIR/pam_touchbridge.so"
echo ""

# 4. Menubar app (bundled in the same Xcode project)
echo "▸ Building menubar app…"
xcodebuild -project TouchBridge.xcodeproj \
  -scheme TouchBridgeMenu \
  -configuration "$XCODE_CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  build 2>&1 | tail -3

# Copy menubar app to build/
MENU_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/TouchBridgeMenu.app"
if [[ -d "$MENU_APP" ]]; then
  rm -rf "$BUILD_DIR/TouchBridgeMenu.app"
  cp -R "$MENU_APP" "$BUILD_DIR/TouchBridgeMenu.app"
  echo "  ✓ Menubar app → $BUILD_DIR/TouchBridgeMenu.app"
else
  echo "  ✗ Menubar app not found at $MENU_APP"
  exit 1
fi
echo ""

echo "━━━ Build Complete ━━━"
echo ""
echo "Built components in $BUILD_DIR/:"
ls -1 "$BUILD_DIR"
echo ""
echo "To run the menubar app:  open $BUILD_DIR/TouchBridgeMenu.app"
echo "To install via CLI:      sudo bash scripts/install.sh"
echo "To install via menubar:  click 'Install TouchBridge' in the menu bar app"
