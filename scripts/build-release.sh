#!/bin/bash
set -euo pipefail

# Builds all release artifacts:
# 1. Daemon binary (release mode)
# 2. PAM module (universal binary)
# 3. Menu bar app (with bundled daemon + PAM + privileged helper)
# 4. CLI installer .pkg (daemon + PAM + scripts, no GUI)
# 5. .dmg with menu bar app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/release"
RELEASE_DIR="$PROJECT_DIR/dist"

# Version: override with VERSION=x.y.z, else derive from latest git tag
VERSION="${VERSION:-$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
if [ -z "$VERSION" ]; then
    echo "ERROR: could not determine version (no git tag found). Set VERSION=x.y.z" >&2
    exit 1
fi

echo "=== TouchBridge Release Builder (v$VERSION) ==="
echo ""

rm -rf "$BUILD_DIR" "$RELEASE_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

# 1. Build daemon
echo "[1/5] Building daemon..."
cd "$PROJECT_DIR/mac/daemon"
swift build -c release 2>&1 | tail -1
cp .build/release/touchbridge "$BUILD_DIR/"
echo "  ✓ Daemon binary built"

# 2. Build PAM module
echo "[2/5] Building PAM module..."
cd "$PROJECT_DIR"
make -C mac/pam clean 2>/dev/null || true
make -C mac/pam 2>&1 | tail -1
cp mac/pam/pam_touchbridge.so "$BUILD_DIR/"
echo "  ✓ PAM module built (universal binary)"

# 3. Build menu bar app (bundles daemon + PAM + helper)
echo "[3/5] Building menu bar app..."
cd "$PROJECT_DIR/mac/menubar"
xcodegen generate 2>&1 | tail -1
xcodebuild -project TouchBridgeMenu.xcodeproj -scheme TouchBridgeMenu \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    build 2>&1 | tail -1
APP_PATH=$(find "$BUILD_DIR/derived" -name "TouchBridgeMenu.app" -type d | head -1)
if [ -n "$APP_PATH" ]; then
    cp -R "$APP_PATH" "$BUILD_DIR/TouchBridge.app"
    echo "  ✓ Menu bar app built"
else
    echo "  ⚠ Menu bar app not found — skipping"
fi

# 4. Create CLI .pkg installer (daemon + PAM + scripts, no GUI)
echo "[4/5] Creating CLI installer package..."
PKG_ROOT="$BUILD_DIR/pkg-root"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/usr/local/lib/pam"
mkdir -p "$PKG_ROOT/usr/local/share/touchbridge"

cp "$BUILD_DIR/touchbridge" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/pam_touchbridge.so" "$PKG_ROOT/usr/local/lib/pam/"
cp "$PROJECT_DIR/scripts/install.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/scripts/uninstall.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/scripts/patch-pam.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/scripts/pam-common.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/mac/daemon/dev.touchbridge.daemon.plist" "$PKG_ROOT/usr/local/share/touchbridge/"

# Post-install script
cat > "$BUILD_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Create directories
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
mkdir -p "$ACTUAL_HOME/Library/Application Support/TouchBridge"
mkdir -p "$ACTUAL_HOME/Library/Logs/TouchBridge"
chmod 700 "$ACTUAL_HOME/Library/Application Support/TouchBridge"

# Install LaunchAgent
PLIST_SRC="/usr/local/share/touchbridge/dev.touchbridge.daemon.plist"
PLIST_DST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
cp "$PLIST_SRC" "$PLIST_DST"
chown "$ACTUAL_USER" "$PLIST_DST"

# Set permissions
chmod 755 /usr/local/bin/touchbridge
chmod 444 /usr/local/lib/pam/pam_touchbridge.so

echo "TouchBridge CLI installed."
echo ""
echo "Activate the sudo hook:"
echo "  sudo bash /usr/local/share/touchbridge/patch-pam.sh"
echo ""
echo "Then start the daemon:"
echo "  touchbridge serve"
echo ""
exit 0
POSTINSTALL
chmod +x "$BUILD_DIR/postinstall"

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$BUILD_DIR" \
    --identifier "dev.touchbridge.cli" \
    --version "$VERSION" \
    --install-location "/" \
    "$RELEASE_DIR/touchbridge-$VERSION.pkg" 2>&1 | tail -1

echo "  ✓ CLI installer package created"

# 5. Create .dmg with menu bar app
echo "[5/5] Creating disk image..."
DMG_DIR="$BUILD_DIR/dmg"
mkdir -p "$DMG_DIR"

if [ -d "$BUILD_DIR/TouchBridge.app" ]; then
    cp -R "$BUILD_DIR/TouchBridge.app" "$DMG_DIR/"
fi

# Create a simple README in the DMG
cat > "$DMG_DIR/README.txt" << README
TouchBridge — Approve macOS authentication from a nearby phone or wearable

INSTALL:
  Drag TouchBridge.app to Applications, then open it.
  The app bundles everything — no terminal needed.

  TouchBridge will appear in your menu bar. Click it to install
  the daemon and PAM module, then pair your phone.

CLI USERS:
  If you prefer the terminal, download touchbridge-$VERSION.pkg instead:
    sudo installer -pkg touchbridge-$VERSION.pkg -target /
    sudo bash /usr/local/share/touchbridge/patch-pam.sh
    touchbridge serve

More info: https://github.com/whjvenyl/touch-bridge
README

hdiutil create \
    -volname "TouchBridge" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$RELEASE_DIR/TouchBridge-$VERSION.dmg" 2>&1 | tail -1

echo "  ✓ Disk image created"

# Summary
echo ""
echo "=== Release Artifacts ==="
ls -lh "$RELEASE_DIR/"
echo ""
echo "  touchbridge-$VERSION.pkg  — CLI installer (brew cask)"
echo "  TouchBridge-$VERSION.dmg  — Menu bar app (direct download)"
echo ""
echo "Ready to upload to GitHub Releases."
