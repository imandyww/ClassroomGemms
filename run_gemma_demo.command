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

DEMO_DEFINES=(
  "--dart-define=VOICE_AGENT_DEMO_MODE=true"
  "--dart-define=VOICE_AGENT_DEMO_ROOT=$ROOT"
)
MAC_APP="$HERE/apps/agent_mac/build/macos/Build/Products/Debug/agent_mac.app"
IOS_APP="$HERE/apps/voice_ios/build/ios/iphonesimulator/Runner.app"
IOS_BUNDLE_ID="com.andywang.voiceagent.voiceIos"
MODEL_SLUG="gemma-4-e2b-it"
SIMULATOR_COPY_BUFFER_BYTES=$((512 * 1024 * 1024))

human_bytes() {
  awk -v bytes="$1" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ");
      value = bytes + 0;
      unit = 1;
      while (value >= 1024 && unit < 5) {
        value = value / 1024;
        unit++;
      }
      if (unit == 1) {
        printf "%d %s", value, units[unit];
      } else {
        printf "%.1f %s", value, units[unit];
      }
    }
  '
}

path_usage_bytes() {
  local path="$1"
  local blocks_kib
  blocks_kib="$(du -sk "$path" | awk '{ print $1 }')"
  echo $((blocks_kib * 1024))
}

available_bytes_for_path() {
  local path="$1"
  df -Pk "$path" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

ensure_full_copy_space() {
  local destination_root="$1"
  local source_bytes available_bytes required_bytes

  source_bytes="$(path_usage_bytes "$SOURCE_MODEL_PATH")"
  available_bytes="$(available_bytes_for_path "$destination_root")"
  required_bytes=$((source_bytes + SIMULATOR_COPY_BUFFER_BYTES))

  if (( available_bytes >= required_bytes )); then
    return 0
  fi

  echo ""
  echo "ERROR: Not enough free disk space for a non-cloned simulator model copy."
  echo "       Model size: $(human_bytes "$source_bytes")"
  echo "       Required free space with buffer: $(human_bytes "$required_bytes")"
  echo "       Available at simulator container: $(human_bytes "$available_bytes")"
  echo ""
  echo "Free disk space or remove stale simulator/Xcode data, then rerun:"
  echo "  ./run_gemma_demo.command"
  return 1
}

sync_simulator_model() {
  local tmp_model_path="$IOS_MODEL_PATH.tmp.$$"

  echo "==> Syncing $MODEL_SLUG into the simulator sandbox..."
  echo "    Using APFS clone copy when available to avoid duplicating the model."
  mkdir -p "$IOS_MODEL_ROOT"
  rm -rf "$tmp_model_path"
  rm -rf "$IOS_MODEL_ROOT/$MODEL_SLUG.tmp."*

  if cp -cRp "$SOURCE_MODEL_PATH" "$tmp_model_path"; then
    rm -rf "$IOS_MODEL_PATH"
    mv "$tmp_model_path" "$IOS_MODEL_PATH"
    return 0
  fi

  rm -rf "$tmp_model_path"
  echo "WARN: APFS clone copy failed; falling back to a full copy."
  ensure_full_copy_space "$IOS_MODEL_ROOT"

  if ditto "$SOURCE_MODEL_PATH" "$tmp_model_path"; then
    rm -rf "$IOS_MODEL_PATH"
    mv "$tmp_model_path" "$IOS_MODEL_PATH"
    return 0
  fi

  rm -rf "$tmp_model_path"
  echo "ERROR: Failed to copy $MODEL_SLUG into the simulator sandbox."
  exit 1
}

if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
  echo "ERROR: Boot an iOS Simulator before running this demo."
  exit 1
fi

echo "==> Preloading $MODEL_SLUG into $ROOT ..."
"$HERE/preload_gemma_demo.command" "$@"

echo ""
echo "==> Killing any running agent_mac instances..."
pkill -f 'agent_mac.app/Contents/MacOS/agent_mac' 2>/dev/null || true
pkill -x agent_mac 2>/dev/null || true
sleep 1

echo "==> Building agent_mac in demo mode..."
(
  cd "$HERE/apps/agent_mac"
  flutter build macos --debug "${DEMO_DEFINES[@]}"
)

echo ""
"$HERE/scripts/sign_macos_app.sh" \
  "$MAC_APP" \
  "$HERE/apps/agent_mac/macos/Runner/DebugProfile.entitlements"

echo ""
echo "==> Launching agent_mac..."
if [ -d "$MAC_APP" ]; then
  open "$MAC_APP"
else
  echo "ERROR: $MAC_APP not found after build"
  exit 1
fi

echo ""
echo "==> Building voice_ios for the booted iOS Simulator in demo mode..."
(
  cd "$HERE/apps/voice_ios"
  flutter build ios --simulator "${DEMO_DEFINES[@]}"
)

if [ ! -d "$IOS_APP" ]; then
  echo "ERROR: $IOS_APP not found after build"
  exit 1
fi

echo ""
echo "==> Installing voice_ios into the booted simulator..."
xcrun simctl install booted "$IOS_APP"

echo "==> Resolving simulator data container..."
IOS_CONTAINER="$(xcrun simctl get_app_container booted "$IOS_BUNDLE_ID" data)"
IOS_MODEL_ROOT="$IOS_CONTAINER/Library/Application Support/gemma4_demo"
IOS_MODEL_PATH="$IOS_MODEL_ROOT/$MODEL_SLUG"
SOURCE_MODEL_PATH="$ROOT/$MODEL_SLUG"

if [ ! -d "$SOURCE_MODEL_PATH" ]; then
  echo "ERROR: Expected preloaded model at $SOURCE_MODEL_PATH"
  exit 1
fi

sync_simulator_model

echo "==> Launching voice_ios on the booted simulator..."
xcrun simctl launch booted "$IOS_BUNDLE_ID"

echo ""
echo "==> Waiting for agent_mac LAN server to come up on :53317..."
TEACHER_URL="http://127.0.0.1:53317/api/localsend/v2/info"
ATTEMPTS=0
MAX_ATTEMPTS=30
until curl -fsS --max-time 2 "$TEACHER_URL" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "WARN: teacher Mac did not answer on :53317 within $((MAX_ATTEMPTS * 2))s."
    echo "      The app may still be loading the model. Check the agent_mac window."
    break
  fi
  sleep 2
done
if [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; then
  echo "    Teacher Mac is responding on :53317."
fi

echo ""
echo "Demo ready."
echo ""
echo "Next steps in agent_mac:"
echo "  1. Click 'Load Preloaded Gemma-4-E2B' if it isn't loading already."
echo "  2. Wait for 'Setup: ready' in the green status bar."
echo "  3. Open Library, pick a starter lesson, then click Start in Live."
echo ""
echo "The simulator student app auto-loads its model and joins the lesson."
