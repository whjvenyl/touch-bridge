#!/bin/bash
# run-ios.sh — Build and install the TouchBridge iOS companion on a
# simulator or connected device, then launch the app.
#
# Device selection (in priority order):
#   1. --device ID        → use the given CoreDevice/simulator UDID
#   2. physical device    → any connected iPad/iPhone via devicectl
#   3. running simulator  → any booted simulator
#   4. boot simulator     → boot the configured simulator and wait
#
# Usage:
#   bash scripts/run-ios.sh                       # auto-pick device
#   bash scripts/run-ios.sh --device ID           # target a specific UDID
#   bash scripts/run-ios.sh --sim "iPad (A16)"    # boot a named simulator
#   bash scripts/run-ios.sh --no-build            # skip xcodebuild
#   bash scripts/run-ios.sh --list                # list devices and exit
#
# NOTE: The iOS simulator has no real BLE radio. The companion will build and
# run, but it cannot actually scan for / pair with the Mac daemon. For real
# end-to-end testing, connect a physical device over USB/Wi-Fi and run this
# script — it will be preferred over any simulator automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_DIR="$PROJECT_DIR/companion/ios"

# --- args ---
DEVICE_OVERRIDE=""
SIM_OVERRIDE=""
DO_BUILD=true
LIST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)    DEVICE_OVERRIDE="$2"; shift ;;
    --sim)       SIM_OVERRIDE="$2"; shift ;;
    --no-build)  DO_BUILD=false ;;
    --list)      LIST_ONLY=true ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

SCHEME="TouchBridge"
BUNDLE_ID="dev.touchbridge.ios-companion"
DEFAULT_SIM="iPhone 16"

# --- list devices and exit if --list ---
if $LIST_ONLY; then
  echo "=== Physical devices (devicectl) ==="
  xcrun devicectl list devices 2>/dev/null || echo "  (devicectl unavailable)"
  echo ""
  echo "=== Simulators ==="
  xcrun simctl list devices available 2>/dev/null | grep -E "iPad|iPhone" | sed 's/^/    /'
  exit 0
fi

echo "=== TouchBridge iOS Companion ==="
echo "Scheme: $SCHEME   Build: $DO_BUILD"
echo ""

# --- generate Xcode project if needed ---
if [[ ! -f "$IOS_DIR/TouchBridge.xcodeproj/project.pbxproj" ]] || \
   [[ "$IOS_DIR/project.yml" -nt "$IOS_DIR/TouchBridge.xcodeproj/project.pbxproj" ]]; then
  echo "- Generating Xcode project (xcodegen)..."
  (cd "$IOS_DIR" && xcodegen generate 2>&1 | tail -3)
fi

# --- collect physical devices ---
PHYSICAL_UDID=""
PHYSICAL_NAME=""
if command -v xcrun &>/dev/null; then
  # devicectl list outputs a space-padded table. The columns are:
  #   Name  Hostname  Identifier  State  Model
  # We extract the UDID (matches UUID format) and check state contains "available".
  while read -r line; do
    # Extract the UDID (UUID format) from the line
    if [[ "$line" =~ ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}) ]]; then
      udid="${BASH_REMATCH[1]}"
      # Check if the line contains "available" or "connected" in the state column
      if echo "$line" | grep -qE "available|connected"; then
        # Extract the name (first field before the hostname)
        PHYSICAL_NAME="$(echo "$line" | awk '{print $1}')"
        PHYSICAL_UDID="$udid"
        break
      fi
    fi
  done < <(xcrun devicectl list devices 2>/dev/null | tail -n +2)
fi

# --- collect booted simulators ---
BOOTED_SIM_UDID=""
BOOTED_SIM_NAME=""
while read -r udid name state; do
  if [[ "$state" == "Booted" ]]; then
    BOOTED_SIM_UDID="$udid"
    BOOTED_SIM_NAME="$name"
    break
  fi
done < <(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        print(f\"{d['udid']}\t{d['name']}\t{d['state']}\")
" 2>/dev/null)

# --- pick a device ---
if [[ -n "$DEVICE_OVERRIDE" ]]; then
  TARGET="$DEVICE_OVERRIDE"
  # Determine if it's a simulator or physical device.
  if xcrun simctl list devices 2>/dev/null | grep -q "$TARGET"; then
    DESTINATION="id=$TARGET"
    DEVICE_TYPE="simulator"
  else
    DESTINATION="id=$TARGET"
    DEVICE_TYPE="physical"
  fi
  echo "- Using specified device: $TARGET ($DEVICE_TYPE)"
elif [[ -n "$PHYSICAL_UDID" ]]; then
  TARGET="$PHYSICAL_UDID"
  DESTINATION="id=$TARGET"
  DEVICE_TYPE="physical"
  echo "- Using physical device: $PHYSICAL_NAME ($TARGET)"
elif [[ -n "$BOOTED_SIM_UDID" ]]; then
  TARGET="$BOOTED_SIM_UDID"
  DESTINATION="id=$TARGET"
  DEVICE_TYPE="simulator"
  echo "- Reusing booted simulator: $BOOTED_SIM_NAME ($TARGET)"
else
  # Boot a simulator.
  SIM_NAME="${SIM_OVERRIDE:-$DEFAULT_SIM}"
  echo "- No device attached. Booting simulator '$SIM_NAME'..."

  # Find the UDID for the named simulator.
  # Use JSON output to avoid regex issues with names containing parentheses.
  SIM_UDID=""
  while read -r udid name; do
    if [[ "$name" == "$SIM_NAME" ]]; then
      SIM_UDID="$udid"
      break
    fi
  done < <(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('isAvailable', False):
            print(f\"{d['udid']}\t{d['name']}\")
" 2>/dev/null)

  if [[ -z "$SIM_UDID" ]]; then
    echo "ERROR: Simulator '$SIM_NAME' not found." >&2
    echo "  Available:" >&2
    xcrun simctl list devices available 2>/dev/null | grep -E "iPad|iPhone" | sed 's/^/    /' >&2
    exit 1
  fi

  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  open -a Simulator 2>/dev/null || true
  echo "  Waiting for simulator to boot..."
  # Wait for boot to complete using simctl list (JSON).
  for _ in $(seq 1 60); do
    STATE="$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d['udid'] == '$SIM_UDID':
            print(d['state'])
            sys.exit(0)
" 2>/dev/null)"
    if [[ "$STATE" == "Booted" ]]; then
      break
    fi
    sleep 2
  done
  TARGET="$SIM_UDID"
  DESTINATION="id=$TARGET"
  DEVICE_TYPE="simulator"
  echo "  OK Booted: $SIM_NAME ($TARGET)"
fi

# --- build ---
if $DO_BUILD; then
  echo ""
  echo "- Building $SCHEME for $DEVICE_TYPE..."
  (cd "$IOS_DIR" && xcodebuild \
    -project TouchBridge.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates \
    build 2>&1 | tail -5)
fi

# --- install + launch ---
APP_PATH="$IOS_DIR/build/DerivedData/Build/Products/Debug-iphonesimulator/TouchBridge.app"
if [[ "$DEVICE_TYPE" == "physical" ]]; then
  APP_PATH="$IOS_DIR/build/DerivedData/Build/Products/Debug-iphoneos/TouchBridge.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: App bundle not found at $APP_PATH" >&2
  echo "  Build it first: cd companion/ios && xcodebuild -project TouchBridge.xcodeproj -scheme $SCHEME build" >&2
  exit 1
fi

echo ""
if [[ "$DEVICE_TYPE" == "simulator" ]]; then
  echo "- Installing on simulator $TARGET..."
  xcrun simctl install "$TARGET" "$APP_PATH"
  echo "- Launching $BUNDLE_ID..."
  xcrun simctl launch "$TARGET" "$BUNDLE_ID"
else
  echo "- Installing on physical device $TARGET..."
  xcrun devicectl device install app --device "$TARGET" "$APP_PATH"
  echo "- Launching $BUNDLE_ID..."
  xcrun devicectl device process launch --device "$TARGET" "$BUNDLE_ID"
fi

echo ""
echo "OK Done. App: $BUNDLE_ID   Device: $TARGET ($DEVICE_TYPE)"
if [[ "$DEVICE_TYPE" == "simulator" ]]; then
  echo "  Logs:    xcrun simctl spawn $TARGET log stream --predicate 'subsystem == dev.touchbridge'"
  echo "  Stop:    xcrun simctl shutdown $TARGET"
else
  echo "  Logs:    xcrun devicectl device process launch --device $TARGET --console"
fi
