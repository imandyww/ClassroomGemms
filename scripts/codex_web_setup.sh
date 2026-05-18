#!/usr/bin/env bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FLUTTER_VERSION="${FLUTTER_VERSION:-3.41.7}"
FLUTTER_INSTALL_ROOT="${FLUTTER_INSTALL_ROOT:-$HOME/.local/share/codex-flutter}"
FLUTTER_SDK_DIR="$FLUTTER_INSTALL_ROOT/flutter-$FLUTTER_VERSION"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
ARCHIVE_PATH="/tmp/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
EXTRACT_ROOT="/tmp/codex-flutter-extract"

if [ ! -x "$FLUTTER_SDK_DIR/bin/flutter" ]; then
  echo "==> Installing Flutter $FLUTTER_VERSION into $FLUTTER_SDK_DIR"
  mkdir -p "$FLUTTER_INSTALL_ROOT"
  rm -rf "$FLUTTER_SDK_DIR" "$EXTRACT_ROOT"
  mkdir -p "$EXTRACT_ROOT"
  curl -fsSL "$FLUTTER_URL" -o "$ARCHIVE_PATH"
  tar -C "$EXTRACT_ROOT" -xf "$ARCHIVE_PATH"
  mv "$EXTRACT_ROOT/flutter" "$FLUTTER_SDK_DIR"
fi

export PATH="$FLUTTER_SDK_DIR/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

echo "==> Flutter SDK"
flutter --version

echo "==> Disabling analytics"
flutter config --no-analytics >/dev/null

echo "==> Resolving workspace dependencies"
cd "$ROOT"
flutter pub get

echo "==> Codex Web setup complete"
