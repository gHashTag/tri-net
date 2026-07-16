#!/bin/bash
# build_ios.sh — Build TriNetVideo for iOS device/simulator
# Usage: bash build_ios.sh [device|simulator]

set -e

MODE=${1:-simulator}
PROJECT_DIR="/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/swift/TriNetVideo"

if [ "$MODE" = "device" ]; then
    echo "Building for iOS device..."
    swift build --package-path "$PROJECT_DIR" -c release --arch arm64
else
    echo "Building for iOS simulator..."
    swift build --package-path "$PROJECT_DIR" -c debug --arch arm64
fi

echo "=== Build complete ==="
echo "Binary: $PROJECT_DIR/.build/release/TriNetVideo"
echo ""
echo "To run on device:"
echo "  1. Open Xcode"
echo "  2. Create new iOS app project"
echo "  3. Copy main.swift content into the project"
echo "  4. Add camera + network permissions to Info.plist"
echo "  5. Build and run on iPhone"
