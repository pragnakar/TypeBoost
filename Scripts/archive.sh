#!/bin/bash
# archive.sh — Create a signed, archived .app for distribution
#
# Usage:
#   ./Scripts/archive.sh [SIGNING_IDENTITY]
#
# If SIGNING_IDENTITY is omitted, ad-hoc signing ("-") is used.
# For distribution, use your Developer ID Application certificate:
#   ./Scripts/archive.sh "Developer ID Application: Your Name (TEAMID)"
#
# Output:
#   build/archive/TypeBoost.xcarchive
#   build/export/TypeBoost.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/archive/TypeBoost.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
SIGNING_IDENTITY="${1:--}"

cd "$PROJECT_DIR"

# Ensure project exists.
if [ ! -d "TypeBoost.xcodeproj" ]; then
    bash Scripts/setup.sh
fi

echo "==> Archiving TypeBoost..."
echo "    Signing Identity: $SIGNING_IDENTITY"

xcodebuild \
    -project TypeBoost.xcodeproj \
    -scheme TypeBoost \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    ENABLE_HARDENED_RUNTIME=YES \
    archive

echo "==> Exporting .app from archive..."

# Create an export options plist for Developer ID distribution.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" \
    || echo "⚠ Archive export failed (expected without a valid signing identity)."

echo ""
echo "✓ Archive complete."
echo "  Archive: $ARCHIVE_PATH"
echo "  Export:  $EXPORT_DIR/TypeBoost.app"
echo ""
echo "Next: ./Scripts/create_dmg.sh $EXPORT_DIR/TypeBoost.app"
