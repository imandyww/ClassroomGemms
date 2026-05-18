#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <app-path> <entitlements-path>" >&2
  exit 64
fi

APP_PATH="$1"
ENTITLEMENTS_PATH="$2"

if [ ! -d "$APP_PATH" ]; then
  echo "WARN: app not found at $APP_PATH" >&2
  exit 0
fi

if [ ! -f "$ENTITLEMENTS_PATH" ]; then
  echo "WARN: entitlements file not found at $ENTITLEMENTS_PATH" >&2
  exit 0
fi

IDENTITY="${MACOS_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$IDENTITY" ]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\([^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$IDENTITY" ]; then
  echo "WARN: no macOS code-signing identity found; leaving $APP_PATH ad-hoc signed." >&2
  echo "      Accessibility approval may stop working after each rebuild until the app is signed with a stable identity." >&2
  exit 0
fi

echo "==> Re-signing $(basename "$APP_PATH") with $IDENTITY"
codesign \
  --force \
  --deep \
  --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS_PATH" \
  "$APP_PATH"
