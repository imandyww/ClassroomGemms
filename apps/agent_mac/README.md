# agent_mac

macOS side of the LAN-paired voice agent demo. It accepts intents from
`voice_ios`, runs the local ReAct loop, and drives desktop automation.

## Standard local run

From the workspace root:

```sh
./rebuild_mac.command
```

Or directly:

```sh
cd apps/agent_mac
flutter build macos --debug
open build/macos/Build/Products/Debug/agent_mac.app
```

## Demo-mode preloaded Gemma

For the macOS + iOS Simulator demo path, run the repo-level helper from the
workspace root:

```sh
./run_gemma_demo.command
```

That flow builds `agent_mac` with:

- `VOICE_AGENT_DEMO_MODE=true`
- `VOICE_AGENT_DEMO_ROOT=/absolute/path/to/.demo-models`

In demo mode, `agent_mac` loads the preloaded `gemma-4-e2b-it` model directly
from:

```text
<repo>/.demo-models/gemma-4-e2b-it
```

It does not auto-download weights, try `gemma-4-e4b-it`, or fall back to
`qwen3-1.7`. If the path is missing or invalid, the app fails loudly and points
back to `./preload_gemma_demo.command`.
