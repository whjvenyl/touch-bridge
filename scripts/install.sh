#!/bin/bash
set -euo pipefail

# TouchBridge Installer
# Builds and installs the daemon, PAM module, and LaunchAgent.
# Patches /etc/pam.d/sudo and /etc/pam.d/screensaver with user confirmation.
# Fully idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DAEMON_BIN="/usr/local/bin/touchbridge"
PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
APP_SUPPORT_DIR="$HOME/Library/Application Support/TouchBridge"
LOG_DIR="$HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_LABEL="dev.touchbridge.daemon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight Checks ---

echo "=== TouchBridge Installer ==="
echo ""

# Check macOS version >= 13.0
MACOS_VERSION=$(sw_vers -productVersion)
MAJOR_VERSION=$(echo "$MACOS_VERSION" | cut -d. -f1)
if [ "$MAJOR_VERSION" -lt 13 ]; then
    error "macOS 13.0 (Ventura) or later is required. You have $MACOS_VERSION."
    exit 1
fi
info "macOS version: $MACOS_VERSION"

# Check SIP status
SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")
if echo "$SIP_STATUS" | grep -q "disabled"; then
    warn "System Integrity Protection is disabled. This is unusual."
    warn "TouchBridge works with SIP enabled — consider re-enabling it."
fi

# Check for root (needed for PAM file modification)
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash scripts/install.sh"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
APP_SUPPORT_DIR="$ACTUAL_HOME/Library/Application Support/TouchBridge"
LOG_DIR="$ACTUAL_HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_PLIST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"

info "Installing for user: $ACTUAL_USER"

# --- Build ---

# Generate protobuf code if tools are available
if command -v protoc-gen-swift &>/dev/null; then
    info "Generating protobuf code..."
    sudo -u "$ACTUAL_USER" bash "$PROJECT_DIR/protocol/generate.sh" 2>&1 | tail -1
else
    warn "protoc-gen-swift not found — using existing generated files."
    warn "Install with: brew install protobuf swift-protobuf"
fi

info "Building daemon..."
cd "$PROJECT_DIR/mac"
sudo -u "$ACTUAL_USER" xcodegen generate 2>&1 | tail -1
DAEMON_DERIVED="$PROJECT_DIR/mac/build"
sudo -u "$ACTUAL_USER" xcodebuild -project TouchBridge.xcodeproj -scheme touchbridge -configuration Release -derivedDataPath "$DAEMON_DERIVED" build 2>&1 | tail -3
DAEMON_BUILD="$DAEMON_DERIVED/Build/Products/Release/touchbridge"
if [ ! -f "$DAEMON_BUILD" ]; then
    error "Daemon build failed — binary not found at $DAEMON_BUILD"
    exit 1
fi
info "Daemon built successfully."

info "Building PAM module..."
cd "$PROJECT_DIR"
make -C mac/pam 2>&1 | tail -1
PAM_BUILD="$PROJECT_DIR/mac/pam/pam_touchbridge.so"
if [ ! -f "$PAM_BUILD" ]; then
    error "PAM module build failed."
    exit 1
fi
info "PAM module built successfully."

# Ad-hoc sign the PAM module so macOS Library Validation doesn't reject it
# when loaded by platform binaries (sudo, etc.). We sign AFTER copying to
# the final location so the code signature's mtime matches the file's mtime
# (signing before copying causes a cs_mtime mismatch that AMFI rejects).

# --- Install Binaries ---

info "Installing daemon binary..."
mkdir -p "$(dirname "$DAEMON_BIN")"
cp "$DAEMON_BUILD" "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"
info "Installed $DAEMON_BIN"

info "Installing PAM module..."
mkdir -p "$(dirname "$PAM_LIB")"
cp "$PAM_BUILD" "$PAM_LIB"
chmod 444 "$PAM_LIB"
# Sign the PAM module in its final location (after copy) so the code
# signature timestamp matches the file mtime. Signing before copying
# causes a cs_mtime mismatch that AMFI rejects on macOS 26+.
if command -v codesign >/dev/null 2>&1; then
    if codesign -s - --force "$PAM_LIB" 2>/dev/null; then
        info "PAM module ad-hoc signed at final location."
    else
        warn "Ad-hoc signing PAM module failed — continuing without signature."
    fi
fi
info "Installed $PAM_LIB"

# --- Create Directories ---

sudo -u "$ACTUAL_USER" mkdir -p "$APP_SUPPORT_DIR"
chmod 700 "$APP_SUPPORT_DIR"
sudo -u "$ACTUAL_USER" mkdir -p "$LOG_DIR"
info "Created application support and log directories."

# --- Patch PAM Files ---
# Uses the shared helper: prefers the unprotected /etc/pam.d/sudo_local hook on
# macOS Sonoma+, falls back to editing /etc/pam.d/sudo directly on older macOS.

# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

# Patch both PAM surfaces at install time. Individual surface toggles are
# handled at runtime via surfaces.json (no root needed).
tb_enable_sudo "prompt"
tb_enable_screensaver "prompt"

# --- Install LaunchAgent ---

info "Installing LaunchAgent..."

# Unload existing agent if running
ACTUAL_UID=$(id -u "$ACTUAL_USER")
launchctl bootout "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

# Write the plist (with correct paths for the actual user)
cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_BIN</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.stderr.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

chown "$ACTUAL_USER" "$LAUNCH_AGENT_PLIST"
chmod 644 "$LAUNCH_AGENT_PLIST"

# Load the agent.
# Redirect all fds so the daemon doesn't inherit the shell's stdout/stderr,
# which would keep the terminal session alive and cause a "killed" message.
launchctl bootstrap "gui/$ACTUAL_UID" "$LAUNCH_AGENT_PLIST" \
    < /dev/null > /dev/null 2>&1 || true
info "LaunchAgent installed and loaded."

# --- Verification ---

echo ""
info "=== Installation Complete ==="
echo ""

# Check daemon is running
if launchctl print "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" &>/dev/null; then
    info "Daemon is running."
else
    warn "Daemon may not be running yet. Check: launchctl print gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL"
fi

# Check socket
SOCK_PATH="$APP_SUPPORT_DIR/daemon.sock"
if [ -S "$SOCK_PATH" ]; then
    info "Socket available at: $SOCK_PATH"
else
    info "Socket will be created when daemon starts: $SOCK_PATH"
fi

echo ""
echo "Next steps:"
echo "  1. Enable surfaces:  touchbridge config set --surface sudo --enable"
echo "     (or use the menubar app Settings → Authentication Surfaces)"
echo "  2. Pair a device:    touchbridge pair"
echo "  3. Test:             sudo echo 'TouchBridge works!'"
echo ""

# Close file descriptors so sudo can exit cleanly.
# Child processes (xcodebuild remnants, launchd-spawned daemon) may hold
# copies of our stdout/stderr pipe. Without closing them, sudo waits for
# EOF, hangs, and gets SIGKILL'd — producing the "killed" message.
exec 1>&- 2>&- 0<&-
