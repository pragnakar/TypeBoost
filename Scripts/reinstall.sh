#!/bin/bash
# reinstall.sh — Full reinstall of TypeBoost: quit, reset permissions, rebuild, repackage, reinstall
#
# Usage:
#   ./Scripts/reinstall.sh [release|debug]
#
# Steps:
#   1. Ask for admin password once via GUI — reused for all privileged operations
#   2. Quit TypeBoost if running
#   3. Reset Accessibility, Input Monitoring, and Automation TCC permissions
#   4. Remove TypeBoost.app from /Applications
#   5. Build a fresh TypeBoost.app
#   6. Create a new .dmg from the fresh build
#   7. Install from the new .dmg to /Applications

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIGURATION="${1:-Release}"
CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIGURATION:0:1}")${CONFIGURATION:1}"

APP_BUNDLE_ID="com.typeboost.app"
APP_NAME="TypeBoost"
INSTALL_PATH="/Applications/${APP_NAME}.app"

echo ""
echo "======================================================"
echo "  TypeBoost Reinstall"
echo "======================================================"
echo ""

# ── 0. Collect admin password once via GUI ────────────────
# A single dialog appears here. The password is stored in memory only
# and passed via stdin (-S) to every subsequent sudo call — no more prompts.
echo "[ 0/6 ] Requesting admin password (one prompt only)..."
ADMIN_PASS=$(osascript -e 'Tell application "SystemUIServer" to display dialog "TypeBoost Reinstall needs admin access." & return & "(Used for: TCC reset, remove/install app)" default answer "" with hidden answer with title "TypeBoost Reinstall" buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null) || {
    echo "✗ Password entry cancelled."
    exit 1
}

# Validate the password works before proceeding.
if ! echo "$ADMIN_PASS" | sudo -S true 2>/dev/null; then
    echo "✗ Incorrect password."
    exit 1
fi
echo "        Authenticated."

# Convenience wrapper — pipes stored password to sudo -S silently.
S() { echo "$ADMIN_PASS" | sudo -S "$@" 2>/dev/null; }

# ── 1. Quit TypeBoost ─────────────────────────────────────
echo "[ 1/6 ] Quitting ${APP_NAME} if running..."
if pgrep -xq "$APP_NAME" 2>/dev/null; then
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep 1
    S pkill -x "$APP_NAME" || true
    echo "        Stopped."
else
    echo "        Not running — skipped."
fi

# ── 2. Reset TCC permissions ──────────────────────────────
echo "[ 2/6 ] Resetting permissions for ${APP_BUNDLE_ID}..."

reset_perm() {
    local service="$1" label="$2"
    if S tccutil reset "$service" "$APP_BUNDLE_ID"; then
        echo "        ✓ ${label} reset"
    else
        echo "        ⚠ ${label} not previously granted — skipped"
    fi
}

reset_perm "Accessibility" "Accessibility"
reset_perm "ListenEvent"   "Input Monitoring"

# ── 3. Remove from /Applications ─────────────────────────
echo "[ 3/6 ] Removing ${INSTALL_PATH}..."
if [ -d "$INSTALL_PATH" ]; then
    S rm -rf "$INSTALL_PATH"
    echo "        Removed."
else
    echo "        Not found — skipped."
fi

# ── 4. Build fresh .app ───────────────────────────────────
echo "[ 4/6 ] Building TypeBoost (${CONFIGURATION})..."
bash "$SCRIPT_DIR/build.sh" "$CONFIGURATION"

APP_PATH="$PROJECT_DIR/build/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "✗ Build output not found at: $APP_PATH"
    exit 1
fi

# ── 5. Create new .dmg from fresh build ──────────────────
echo "[ 5/6 ] Creating DMG from fresh build..."
bash "$SCRIPT_DIR/create_dmg.sh" "$APP_PATH"

DMG_PATH="$PROJECT_DIR/TypeBoost.dmg"
if [ ! -f "$DMG_PATH" ]; then
    echo "✗ DMG not found at: $DMG_PATH"
    exit 1
fi
echo "        DMG: $DMG_PATH"

# ── 6. Install from new .dmg ──────────────────────────────
echo "[ 6/6 ] Installing to /Applications from new DMG..."
MOUNT_POINT=$(mktemp -d /tmp/typeboost-dmg-XXXX)

hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
S cp -R "$MOUNT_POINT/${APP_NAME}.app" /Applications/
hdiutil detach "$MOUNT_POINT" -quiet
rm -rf "$MOUNT_POINT"

if [ -d "$INSTALL_PATH" ]; then
    echo "        ✓ Installed at $INSTALL_PATH"
else
    echo "✗ Installation failed — app not found at $INSTALL_PATH"
    exit 1
fi

# ── Launch ────────────────────────────────────────────────
unset ADMIN_PASS

echo "[ 7/7 ] Launching ${APP_NAME}..."
open "$INSTALL_PATH"
echo "        Launched."

echo ""
echo "======================================================"
echo "  Done. TypeBoost is running."
echo "  Grant Accessibility + Input Monitoring permissions"
echo "  if prompted by macOS."
echo "======================================================"
echo ""