#!/bin/bash
# create_dmg.sh — Package TypeBoost.app into a distributable .DMG installer
#
# Usage:
#   ./Scripts/create_dmg.sh [path/to/TypeBoost.app]
#
# If no path is given, it looks in the default build output directory.
#
# Output:
#   TypeBoost.dmg  (project root)
#
# The DMG includes:
#   • TypeBoost.app
#   • A symlink to /Applications (for drag-to-install)
#   • A background image placeholder
#   • Volume icon set from the app icon

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Locate the .app
APP_PATH="${1:-$PROJECT_DIR/build/Build/Products/Release/TypeBoost.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "✗ TypeBoost.app not found at: $APP_PATH"
    echo "  Build the app first with: ./Scripts/build.sh release"
    exit 1
fi

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

DMG_PATH="$PROJECT_DIR/TypeBoost.dmg"
STAGING_DIR="$PROJECT_DIR/.dmg-staging"

echo "==> Packaging TypeBoost ${VERSION} into DMG..."

# Clean up previous artifacts.
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# Copy .app to staging.
echo "    Copying TypeBoost.app..."
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink for drag-to-install.
ln -s /Applications "$STAGING_DIR/Applications"

# Create the DMG.
echo "    Creating DMG..."
hdiutil create \
    -volname "TypeBoost" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Clean up staging.
rm -rf "$STAGING_DIR"

# Verify.
if [ -f "$DMG_PATH" ]; then
    SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
    echo ""
    echo "✓ DMG created successfully."
    echo "  Path: $DMG_PATH"
    echo "  Size: $SIZE"
    echo ""
    echo "Distribution checklist:"
    echo "  1. Notarise with: xcrun notarytool submit $DMG_PATH --apple-id <ID> --team-id <TEAM>"
    echo "  2. Staple with:   xcrun stapler staple $DMG_PATH"
    echo "  3. Distribute the .dmg file"
else
    echo "✗ DMG creation failed."
    exit 1
fi
