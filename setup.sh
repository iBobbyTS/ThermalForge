#!/bin/bash
#
# ThermalForge Setup
# Builds the app, assembles a staged bundle, verifies its signature, and replaces
# the installed app. No sudo anywhere: the bundle is user-owned, and its embedded
# privileged helper is registered by the app itself on first launch.
#
# Run once: ./setup.sh
#

set -e

cd "$(dirname "$0")"

CLI=".build/release/thermalforge"
APP_BINARY=".build/release/ThermalForgeApp"
HELPER=".build/release/thermalforge-helper"
FINAL="/Applications/ThermalForge.app"
STAGING="/Applications/ThermalForge-new.app"

echo "Building ThermalForge (release)..."
swift build -c release

# Generate the app icon only when it's missing.
if [ ! -f ThermalForge.icns ]; then
    echo "Generating app icon..."
    swift Scripts/generate-icon.swift
    iconutil -c icns ThermalForge.iconset -o ThermalForge.icns
fi

echo "Assembling staged bundle at $STAGING..."
# build-app assembles the three executables + Info.plist + embedded LaunchDaemon
# plist, ad-hoc signs them inside-out, and self-verifies with
# `codesign --verify --deep --strict`. Its nonzero exit is fatal.
"$CLI" build-app \
    --binary "$APP_BINARY" \
    --cli "$CLI" \
    --helper "$HELPER" \
    --icon ThermalForge.icns \
    --dest "$STAGING"

echo "Verifying staged bundle signature..."
codesign --verify --deep --strict "$STAGING"

# Quit any running instance so the replacement takes effect: macOS would otherwise
# keep the old in-memory process alive and just re-activate it on `open`.
pkill -x ThermalForgeApp 2>/dev/null || true
sleep 1

echo "Replacing $FINAL..."
if [ -e "$FINAL" ] && ! rm -rf "$FINAL" 2>/dev/null; then
    echo ""
    echo "ERROR: could not remove the existing $FINAL (likely a root-owned legacy bundle)."
    echo "Run the legacy cleanup once, then re-run ./setup.sh:"
    echo "  sudo launchctl bootout system/com.thermalforge.daemon; sudo rm -rf $FINAL /Library/LaunchDaemons/com.thermalforge.daemon.plist /usr/local/bin/thermalforge"
    exit 1
fi
mv "$STAGING" "$FINAL"

# Strip quarantine on anything Finder dragged in, then launch.
xattr -cr "$FINAL"
open "$FINAL"

echo ""
echo "ThermalForge installed."
echo "  - Open from Spotlight: search 'ThermalForge'"
echo "  - Open from Finder: Applications > ThermalForge"
echo ""
echo "On first launch ThermalForge asks for one system authorization to register its"
echo "embedded background helper (System Settings > General > Login Items & Extensions)."
echo "The app handles that registration itself — no sudo, no separate install step."
