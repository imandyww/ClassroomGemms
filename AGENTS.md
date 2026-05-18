# Repository Instructions

## Workspace

- This repository is a Flutter workspace rooted at `pubspec.yaml`.
- Apps:
  - `apps/agent_mac`: macOS desktop app
  - `apps/voice_ios`: iOS app
- Shared packages live under `packages/`.

## Codex Web

- Codex Web cloud tasks run in a Linux container.
- Do not try to validate changes by building `macos` or `ios` targets in the cloud.
- For cloud validation, prefer workspace-wide analysis plus package-level tests.
- If a task depends on a real macOS or iOS runtime, make the code change and note that final verification must happen locally on macOS.

## Setup

- Run `./scripts/codex_web_setup.sh` from the repository root.

## Validation

- Run `flutter analyze` from the repository root.
- Run `flutter test packages/localsend_common/test` from the repository root.
- Use `./rebuild_mac.command`, `./rebuild_both.command`, `./preload_gemma_demo.command`, and `./run_gemma_demo.command` only in a local macOS environment.

## Notes

- The workspace currently uses Flutter `3.41.7` and Dart `3.11.5`.
- Demo-mode model assets live under `.demo-models`.
- Ignore `ref/` unless the task explicitly references it.
