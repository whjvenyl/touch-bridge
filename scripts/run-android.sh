#!/bin/bash
# run-android.sh — Build and launch the TouchBridge Android companion in the emulator.
#
# Boots an AVD (if no device is already attached), builds the debug APK for the
# selected module, installs it, and launches the main activity.
#
# Usage:
#   bash scripts/run-android.sh              # phone app (default)
#   bash scripts/run-android.sh phone        # phone app
#   bash scripts/run-android.sh wear         # wear OS app
#   bash scripts/run-android.sh --avd NAME   # override AVD
#   bash scripts/run-android.sh --no-build   # skip gradle build, just install+launch
#
# NOTE: The Android emulator has no real BLE radio. The companion will build and
# run, but it cannot actually scan for / pair with the Mac daemon. Use this for
# UI iteration and build verification. For real end-to-end testing, install the
# APK on a physical device (see companion/android/README or scripts/install.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$PROJECT_DIR/companion/android"

# --- args ---
MODULE="app"
AVD_OVERRIDE=""
DO_BUILD=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    phone)  MODULE="app"  ;;
    wear)   MODULE="wear" ;;
    --avd)  AVD_OVERRIDE="$2"; shift ;;
    --no-build) DO_BUILD=false ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
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

# --- pick a device: reuse a booted emulator, else boot the AVD ---
BOOTED_SERIAL=""
while read -r line; do
  # adb devices lines look like: "emulator-5554\tdevice"
  serial="${line%%$'\t'*}"
  state="${line#*$'\t'}"
  if [[ "$state" == "device" && "$serial" == emulator-* ]]; then
    BOOTED_SERIAL="$serial"
    break
  fi
done < <("$ADB" devices | tail -n +2 | grep -v '^$')

if [[ -n "$BOOTED_SERIAL" ]]; then
  echo "▸ Reusing running emulator: $BOOTED_SERIAL"
else
  echo "▸ No emulator running. Booting AVD '$AVD'…"
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
  BOOTED_SERIAL="$("$ADB" devices | tail -n +2 | grep -v '^$' | head -1 | cut -f1)"
  echo "  ✓ Booted: $BOOTED_SERIAL"
fi
ADB_ARGS="-s $BOOTED_SERIAL"

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
echo "▸ Installing $APK…"
"$ADB" $ADB_ARGS install -r "$APK"

echo "▸ Launching $ACTIVITY…"
"$ADB" $ADB_ARGS shell am start -n "$APPLICATION_ID/$ACTIVITY"

echo ""
echo "✓ Done. App: $APPLICATION_ID   Device: $BOOTED_SERIAL"
echo "  Logs:    $ADB $ADB_ARGS logcat -s TouchBridge:V"
echo "  Stop:    $ADB $ADB_ARGS emu kill"
