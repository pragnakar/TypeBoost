#!/bin/bash
# setup.sh — Generate the Xcode project from project.yml using XcodeGen
#
# Prerequisites:
#   brew install xcodegen
#
# Usage:
#   cd TypeBoost
#   ./Scripts/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Checking for XcodeGen..."
if ! command -v xcodegen &>/dev/null; then
    echo "    XcodeGen not found. Installing via Homebrew..."
    brew install xcodegen
fi

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate --spec project.yml

echo ""
echo "✓ TypeBoost.xcodeproj generated successfully."
echo ""
echo "Next steps:"
echo "  1. open TypeBoost.xcodeproj"
echo "  2. Select the 'TypeBoost' scheme"
echo "  3. Build & Run (⌘R)"
echo ""
echo "Before running, grant permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  System Settings → Privacy & Security → Input Monitoring"
