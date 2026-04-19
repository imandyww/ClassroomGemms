#!/usr/bin/env bash
# Double-click this file in Finder, or run it from Terminal, to rebuild and
# relaunch both apps with the latest code changes.
#
# Usage:
#   chmod +x rebuild_both.command  (once)
#   ./rebuild_both.command            # rebuild & relaunch agent_mac, then run voice_ios on iPhone
#   SKIP_IOS=1 ./rebuild_both.command # rebuild & relaunch agent_mac only
#
# Requires: flutter in PATH, Xcode installed, and (for the iOS step) either
# a physical iPhone over USB/wifi or a booted iOS Simulator.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "==> Killing any running agent_mac instances..."
# Match both the bundle id and the binary name so we don't leave a zombie
# process holding port 53317 or hung on a model download.
pkill -f 'agent_mac.app/Contents/MacOS/agent_mac' 2>/dev/null || true
pkill -x agent_mac 2>/dev/null || true
sleep 1

echo "==> Running flutter pub get at root (workspace)..."
flutter pub get

echo ""
echo "==> Rebuilding agent_mac (Debug)..."
(
  cd "$HERE/apps/agent_mac"
  flutter build macos --debug
)

echo ""
echo "==> Launching agent_mac..."
APP="$HERE/apps/agent_mac/build/macos/Build/Products/Debug/agent_mac.app"
if [ -d "$APP" ]; then
  open "$APP"
else
  echo "WARN: $APP not found after build"
fi

if [ "${SKIP_IOS:-0}" = "1" ]; then
  echo ""
  echo "==> SKIP_IOS=1 — done. agent_mac should be running."
  exit 0
fi

echo ""
echo "==> Rebuilding voice_ios on the currently booted iPhone or Simulator..."
echo "    (If this hangs or errors, run with SKIP_IOS=1 to just rebuild Mac.)"
(
  cd "$HERE/apps/voice_ios"
  flutter run -d 'iPhone'
)
