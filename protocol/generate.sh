#!/bin/bash
set -euo pipefail

# TouchBridge Protocol Code Generator (Swift)
#
# Generates Swift protobuf code from the canonical .proto schema.
# The generated file is gitignored — run this after cloning or when
# the .proto file changes.
#
# Android generates its own protobuf code at build time via the Gradle
# protobuf plugin (see companion/android/app/build.gradle.kts).
#
# Requires: brew install protobuf swift-protobuf
#
# Usage:
#   bash protocol/generate.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_FILE="$SCRIPT_DIR/proto/touchbridge.proto"
SWIFT_OUT="$SCRIPT_DIR/swift/Sources/TouchBridgeProtocol/Generated"

echo "=== TouchBridge Protocol Generator ==="
echo ""

if ! command -v protoc-gen-swift &>/dev/null; then
    echo "✗ protoc-gen-swift not found. Install with: brew install swift-protobuf"
    exit 1
fi

echo "Generating Swift..."
mkdir -p "$SWIFT_OUT"
protoc \
    --swift_opt=Visibility=Public \
    --swift_out="$SWIFT_OUT" \
    --proto_path="$SCRIPT_DIR/proto" \
    "$PROTO_FILE"
echo "  ✓ $SWIFT_OUT/touchbridge.pb.swift"

echo ""
echo "Done. Android protobuf is generated at build time by Gradle."
