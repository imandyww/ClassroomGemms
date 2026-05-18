import 'dart:io';

import 'package:path/path.dart' as p;

import 'hf_downloader.dart';

class VoiceAgentDemoSettings {
  final bool enabled;
  final String hostRootPath;
  final String preloadCommand;
  final String simulatorSubdirectory;
  final HfGemma4Spec spec;
  final String sourceLabel;

  const VoiceAgentDemoSettings({
    required this.enabled,
    required this.hostRootPath,
    this.preloadCommand = './preload_gemma_demo.command',
    this.simulatorSubdirectory = 'gemma4_demo',
    this.spec = gemma4E2b,
    this.sourceLabel = 'Preloaded Gemma-4-E2B',
  });

  bool get hasHostRootPath => hostRootPath.trim().isNotEmpty;

  String requireHostRootPath() {
    if (hasHostRootPath) {
      return hostRootPath;
    }
    throw StateError(
      'VOICE_AGENT_DEMO_ROOT is required when VOICE_AGENT_DEMO_MODE=true.',
    );
  }

  String desktopModelPath() {
    return p.join(requireHostRootPath(), spec.slug);
  }

  Future<String> simulatorModelPath(
    Future<Directory> Function() getAppSupportDirectory,
  ) async {
    final appSupport = await getAppSupportDirectory();
    return p.join(appSupport.path, simulatorSubdirectory, spec.slug);
  }
}

const voiceAgentDemoSettings = VoiceAgentDemoSettings(
  enabled: bool.fromEnvironment('VOICE_AGENT_DEMO_MODE'),
  hostRootPath: String.fromEnvironment('VOICE_AGENT_DEMO_ROOT'),
);
