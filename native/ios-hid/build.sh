#!/bin/bash
# Build fs-ios-bridge - iOS Simulator HID event injection tool
# Requires Xcode with CoreSimulator + SimulatorKit frameworks

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/fs-ios-bridge}"

clang -fobjc-arc \
    -framework Foundation \
    -framework CoreGraphics \
    -F /Library/Developer/PrivateFrameworks \
    -F /Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks \
    -o "$OUTPUT" \
    "$SCRIPT_DIR/fs_ios_bridge.m"

echo "Built: $OUTPUT"
