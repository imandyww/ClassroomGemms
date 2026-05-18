## v1.14.1
- Refreshed the vendored Flutter package dependency constraints to the newest versions resolvable with this workspace while keeping the patched Cactus `v1.14` engine API intact.

## v1.14.0
- Synced the vendored Apple engine to upstream Cactus `v1.14` (`09d3d79`) while preserving the local `modelPath` and context-size initialization patch used by this workspace
- Removed the stale iOS `whisper.xcframework` pod reference; the package now vendors the updated `cactus.xcframework` plus the existing `cactus_util.xcframework`

## v1.3.0
- Renamed `CactusTelemetry` to `CactusConfig` for configuration APIs
- Added `CactusConfig.setProKey()` to enable NPU acceleration
- Added `forceTools` parameter to `CactusCompletionParams` for forcing tool calling output

## v1.2.1
- Added `reset()` method to `CactusLM` and `CactusSTT` classes for clearing context without unloading models
- Added `audioStream` parameter support in `CactusSTT` transcription methods for streaming audio input
- Enhanced transcription methods to support both file path and audio stream inputs

## v1.2.0
- Move to cactus whisper
- Memory optimizations
- Sync binaries with latest cactus engine

## v1.0.2

- Synced binaries with the latest Cactus engine
- Added support for vision on LFM2 models

## v1.0.1

- Synced binaries with the latest Cactus engine
- Added support for tool calling on LFM2 models
- Drop vosk and default to whisper for STT

## v1.0.0

This release includes support for:
- **Language Models**: 270M to 1.7B parameters
  - Google Gemma-3 (270M, 1B)
  - Qwen3 (600M, 1.7B)
  - SmolLM2 (360M)
  - LiquidAI LFM2 (350M, 700M, 1.2B)
- **Embedding Models**:
  - Qwen3-Embedding (600M)
  - Nomic-Embed-Text-v2-MoE
