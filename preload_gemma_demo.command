#!/usr/bin/env bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ROOT="${VOICE_AGENT_DEMO_ROOT:-$HERE/.demo-models}"
if [ -d "$ROOT" ]; then
  ROOT="$(cd "$ROOT" && pwd -P)"
else
  ROOT_PARENT="$(cd "$(dirname "$ROOT")" && pwd -P)"
  ROOT="$ROOT_PARENT/$(basename "$ROOT")"
fi

echo "==> Preparing demo model root at $ROOT"
mkdir -p "$ROOT"

echo "==> Running flutter pub get at root (workspace)..."
flutter pub get

echo ""
echo "==> Preloading gemma-4-e2b-it into $ROOT ..."
(
  cd "$HERE/packages/agent_llm"
  dart run bin/preload_gemma_demo.dart --root "$ROOT" "$@"
)
