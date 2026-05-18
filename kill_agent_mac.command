#!/usr/bin/env bash
# Double-click to force-quit any running agent_mac instances. Useful when the
# app hangs on a download and Cmd+Q doesn't work.
set -euo pipefail

echo "==> Killing agent_mac..."
pkill -f 'agent_mac.app/Contents/MacOS/agent_mac' 2>/dev/null || true
pkill -x agent_mac 2>/dev/null || true
sleep 1

if pgrep -x agent_mac >/dev/null; then
  echo "agent_mac still running; sending SIGKILL..."
  pkill -9 -x agent_mac 2>/dev/null || true
  pkill -9 -f 'agent_mac.app/Contents/MacOS/agent_mac' 2>/dev/null || true
fi

echo "Done. No agent_mac processes found running."
