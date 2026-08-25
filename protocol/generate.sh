#!/bin/bash
set -euo pipefail

# TouchBridge Protocol Code Generator (Manual Fallback)
#
# Normally, protobuf code is generated at BUILD TIME:
#   - Swift: SwiftProtobufPlugin SPM build plugin (see Package.swift)
#   - Android: protobuf Gradle plugin 0.10.0 (see app/build.gradle.kts)
#
# This script is a FALLBACK for manual generation when build plugins are
# unavailable (e.g. CI without protoc, debugging proto output, etc.).
#
# Requirements:
#   brew install protobuf swift-protobuf
#
# Usage:
#   bash protocol/generate.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_FILE="$SCRIPT_DIR/proto/touchbridge.proto"

# Swift output — manual fallback only (SPM plugin generates at build time)
SWIFT_OUT="$SCRIPT_DIR/swift/Sources/TouchBridgeProtocol/Generated"
mkdir -p "$SWIFT_OUT"

# Kotlin output — manual fallback only (Gradle plugin generates at build time)
KOTLIN_OUT="$SCRIPT_DIR/../companion/android/app/src/main/java"
mkdir -p "$KOTLIN_OUT"

echo "=== TouchBridge Protocol Generator (Manual Fallback) ==="
echo ""
echo "NOTE: Build-time generation is preferred:"
echo "  Swift:   swift build   (uses SwiftProtobufPlugin SPM plugin)"
echo "  Android: ./gradlew build  (uses protobuf Gradle plugin)"
echo ""

# Generate Swift
echo "[1/2] Generating Swift..."
protoc \
    --swift_opt=Visibility=Public \
    --swift_out="$SWIFT_OUT" \
    --proto_path="$SCRIPT_DIR/proto" \
    "$PROTO_FILE"
echo "  ✓ Swift generated to $SWIFT_OUT"

# Generate Kotlin + Java (Kotlin DSL references Java classes)
echo "[2/2] Generating Kotlin..."
protoc \
    --kotlin_out="$KOTLIN_OUT" \
    --java_out="$KOTLIN_OUT" \
    --proto_path="$SCRIPT_DIR/proto" \
    "$PROTO_FILE"
echo "  ✓ Kotlin generated to $KOTLIN_OUT"

echo ""
echo "Done."
