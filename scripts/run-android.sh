#!/bin/bash
# run-android.sh — Build and install the TouchBridge Android companion on a
# device or emulator, then launch the main activity.
#
# Device selection (in priority order):
#   1. --device SERIAL   → use the given adb serial
#   2. physical device   → any attached non-emulator in "device" state
#   3. running emulator  → any booted emulator-* in "device" state
#   4. boot the AVD      → launch the configured AVD and wait for boot
#
# Usage:
#   bash scripts/run-android.sh                  # phone app, auto-pick device
#   bash scripts/run-android.sh phone            # phone app
#   bash scripts/run-android.sh wear             # wear OS app
#   bash scripts/run-android.sh --device SERIAL  # target a specific adb serial
#   bash scripts/run-android.sh --avd NAME       # override AVD to boot
#   bash scripts/run-android.sh --no-build       # skip gradle build
#   bash scripts/run-android.sh --list           # list attached devices and exit
#
# NOTE: The Android emulator has no real BLE radio. The companion will build and
# run, but it cannot actually scan for / pair with the Mac daemon. For real
# end-to-end testing, plug in a physical device (USB/Wi-Fi debugging enabled) and
# run this script — it will be preferred over any emulator automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$PROJECT_DIR/companion/android"

# --- args ---
MODULE="app"
AVD_OVERRIDE=""
DEVICE_OVERRIDE=""
DO_BUILD=true
LIST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    phone)  MODULE="app"  ;;
    wear)   MODULE="wear" ;;
    --avd)  AVD_OVERRIDE="$2"; shift ;;
    --device) DEVICE_OVERRIDE="$2"; shift ;;
    --no-build) DO_BUILD=false ;;
    --list) LIST_ONLY=true ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$MODULE" in
  app)  APPLICATION_ID="dev.touchbridge.android"; ACTIVITY="dev.touchbridge.android.MainActivity"; DEFAULT_AVD="Pixel_10" ;;
  wear) APPLICATION_ID="dev.touchbridge.wear";    ACTIVITY="dev.touchbridge.wear.MainActivity";    DEFAULT_AVD="Wear_OS_XL_Round" ;;
esac

AVD="${AVD_OVERRIDE:-$DEFAULT_AVD}"

# --- locate SDK ---
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [[ ! -d "$ANDROID_HOME" ]]; then
  echo "✗ Android SDK not found. Set ANDROID_HOME or install to ~/Library/Android/sdk" >&2
  exit 1
fi
export ANDROID_HOME
ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
for bin in "$ADB" "$EMULATOR"; do
  [[ -x "$bin" ]] || { echo "✗ Missing binary: $bin" >&2; exit 1; }
done

echo "━━━ TouchBridge Android Companion ━━━"
echo "Module: $MODULE   AVD: $AVD   Build: $DO_BUILD"
echo ""

# --- list attached devices and exit if --list ---
if $LIST_ONLY; then
  echo "Attached devices (adb):"
  "$ADB" devices -l | tail -n +2 | grep -v '^$' || true
  echo ""
  echo "Available AVDs:"
  "$EMULATOR" -list-avds | sed 's/^/    /'
  exit 0
fi

# --- collect attached devices: physical first, then emulator ---
PHYSICAL_SERIAL=""
EMU_SERIAL=""
while read -r line; do
  # adb devices lines look like: "serial\tstate"
  serial="${line%%$'\t'*}"
  state="${line#*$'\t'}"
  [[ "$state" == "device" ]] || continue
  if [[ "$serial" == emulator-* ]]; then
    [[ -z "$EMU_SERIAL" ]] && EMU_SERIAL="$serial"
  else
    [[ -z "$PHYSICAL_SERIAL" ]] && PHYSICAL_SERIAL="$serial"
  fi
done < <("$ADB" devices | tail -n +2 | grep -v '^$')

# --- pick a device ---
if [[ -n "$DEVICE_OVERRIDE" ]]; then
  TARGET="$DEVICE_OVERRIDE"
  # Verify it's actually present and in "device" state.
  if ! "$ADB" devices | tail -n +2 | grep -v '^$' | cut -f1 | grep -qx "$TARGET"; then
    echo "✗ Device '$TARGET' not found in 'adb devices'." >&2
    echo "  Available:" >&2
    "$ADB" devices | tail -n +2 | grep -v '^$' | sed 's/^/    /' >&2
    exit 1
  fi
  echo "▸ Using specified device: $TARGET"
elif [[ -n "$PHYSICAL_SERIAL" ]]; then
  TARGET="$PHYSICAL_SERIAL"
  echo "▸ Using physical device: $TARGET"
elif [[ -n "$EMU_SERIAL" ]]; then
  TARGET="$EMU_SERIAL"
  echo "▸ Reusing running emulator: $TARGET"
else
  echo "▸ No device attached. Booting AVD '$AVD'…"
  if ! "$EMULATOR" -list-avds | grep -qx "$AVD"; then
    echo "✗ AVD '$AVD' not found. Available:" >&2
    "$EMULATOR" -list-avds | sed 's/^/    /' >&2
    echo "    Create one with: avdmanager create avd -n $AVD -k 'system-images;android-36;google_apis;arm64-v8a'" >&2
    exit 1
  fi
  # Boot in background; -no-snapshot-load gives a clean state, -no-audio avoids ding spam.
  "$EMULATOR" -avd "$AVD" -no-snapshot-load -no-audio -no-boot-anim >/dev/null 2>&1 &
  EMU_PID=$!
  echo "  Emulator PID: $EMU_PID (waiting for boot…)"

  # Wait for the device to show up in adb, then for boot_completed.
  "$ADB" wait-for-device
  echo "  Device visible to adb. Waiting for sys.boot_completed…"
  for _ in $(seq 1 120); do
    if [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
      break
    fi
    sleep 2
  done
  if [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; then
    echo "✗ Emulator did not finish booting within 4 min." >&2
    exit 1
  fi
  TARGET="$("$ADB" devices | tail -n +2 | grep -v '^$' | head -1 | cut -f1)"
  echo "  ✓ Booted: $TARGET"
fi
ADB_ARGS="-s $TARGET"

# --- build ---
if $DO_BUILD; then
  echo ""
  echo "▸ Building :$MODULE debug APK…"
  (cd "$ANDROID_DIR" && ./gradlew ":$MODULE:assembleDebug" --quiet)
fi

APK="$ANDROID_DIR/$MODULE/build/outputs/apk/debug/$MODULE-debug.apk"
if [[ ! -f "$APK" ]]; then
  echo "✗ APK not found at $APK" >&2
  echo "  Build it first: (cd companion/android && ./gradlew :$MODULE:assembleDebug)" >&2
  exit 1
fi

# --- install + launch ---
echo ""
echo "▸ Installing ${APK}…"
"$ADB" $ADB_ARGS install -r "$APK"

echo "▸ Launching ${ACTIVITY}…"
"$ADB" $ADB_ARGS shell am start -n "$APPLICATION_ID/$ACTIVITY"

echo ""
echo "✓ Done. App: $APPLICATION_ID   Device: $TARGET"
echo "  Logs:    $ADB $ADB_ARGS logcat -s TouchBridge:V"
if [[ "$TARGET" == emulator-* ]]; then
  echo "  Stop:    $ADB $ADB_ARGS emu kill"
else
  echo "  Uninstall: $ADB $ADB_ARGS uninstall $APPLICATION_ID"
fi
