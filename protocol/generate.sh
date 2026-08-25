#!/bin/bash
set -euo pipefail

# TouchBridge Protocol Code Generator
#
# Generates platform-specific protobuf code from the canonical .proto schema.
#
# SWIFT: Generated .pb.swift is committed to git. Run this script only when
#   the .proto file changes, then commit the regenerated output.
#   Requires: brew install protobuf swift-protobuf
#
# ANDROID: Generated at build time by the Gradle protobuf plugin (0.10.0).
#   This script can regenerate for debugging, but ./gradlew build does it
#   automatically. Requires: brew install protobuf
#
# Usage:
#   bash protocol/generate.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_FILE="$SCRIPT_DIR/proto/touchbridge.proto"

SWIFT_OUT="$SCRIPT_DIR/swift/Sources/TouchBridgeProtocol/Generated"
KOTLIN_OUT="$SCRIPT_DIR/../companion/android/app/src/main/java"

echo "=== TouchBridge Protocol Generator ==="
echo ""

# --- Swift ---
echo "[1/2] Generating Swift..."
if ! command -v protoc-gen-swift &>/dev/null; then
    echo "  ✗ protoc-gen-swift not found. Install with: brew install swift-protobuf"
    exit 1
fi
mkdir -p "$SWIFT_OUT"
protoc \
    --swift_opt=Visibility=Public \
    --swift_out="$SWIFT_OUT" \
    --proto_path="$SCRIPT_DIR/proto" \
    "$PROTO_FILE"
echo "  ✓ $SWIFT_OUT/touchbridge.pb.swift"
echo "  → Commit this file when the .proto changes."

# --- Kotlin + Java ---
echo "[2/2] Generating Kotlin (debug fallback — Gradle does this at build time)..."
mkdir -p "$KOTLIN_OUT"
protoc \
    --kotlin_out="$KOTLIN_OUT" \
    --java_out="$KOTLIN_OUT" \
    --proto_path="$SCRIPT_DIR/proto" \
    "$PROTO_FILE"
echo "  ✓ $KOTLIN_OUT/dev/touchbridge/android/proto/"

echo ""
echo "Done."
