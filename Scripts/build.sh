#!/bin/bash
# build.sh — Build TypeBoost from the command line
#
# Usage:
#   ./Scripts/build.sh [release|debug]
#
# Outputs:
#   build/Release/TypeBoost.app  (or build/Debug/...)
#
# Prerequisites:
#   - Xcode 15+ with command-line tools installed
#   - The .xcodeproj must exist (run setup.sh first)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

CONFIGURATION="${1:-Release}"
CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIGURATION:0:1}")${CONFIGURATION:1}"

echo "==> Building TypeBoost ($CONFIGURATION)..."

cd "$PROJECT_DIR"

# Ensure the .xcodeproj exists.
if [ ! -d "TypeBoost.xcodeproj" ]; then
    echo "    Xcode project not found. Running setup.sh first..."
    bash Scripts/setup.sh
fi

xcodebuild \
    -project TypeBoost.xcodeproj \
    -scheme TypeBoost \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    build

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/TypeBoost.app"

if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✓ Build succeeded."
    echo "  App: $APP_PATH"
    echo ""
    echo "To create a DMG installer, run:"
    echo "  ./Scripts/create_dmg.sh"
else
    echo "✗ Build failed — app bundle not found."
    exit 1
fi
