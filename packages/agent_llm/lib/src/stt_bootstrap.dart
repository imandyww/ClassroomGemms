import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'demo_mode.dart';
import 'hf_downloader.dart';
import 'lm_bootstrap.dart'
    show
        AppSupportDirectoryResolver,
        GemmaInstallHook,
        LmRuntimeProfile,
        RuntimeProfileResolver,
        StatusCb;
import 'model_picker.dart';

Future<LmRuntimeProfile> _defaultResolveRuntimeProfile(DeviceTier tier) async {
  if (tier == DeviceTier.desktop) {
    return LmRuntimeProfile.desktop;
  }
  if (!Platform.isIOS) {
    return LmRuntimeProfile.iosDevice;
  }

  final iosInfo = await DeviceInfoPlugin().iosInfo;
  return iosInfo.isPhysicalDevice
      ? LmRuntimeProfile.iosDevice
      : LmRuntimeProfile.iosSimulator;
}

Future<Directory> _defaultGetAppSupportDirectory() =>
    getApplicationSupportDirectory();

Future<Gemma4InstallResult> _defaultEnsureGemmaInstall({
  required HfGemma4Spec spec,
  bool forceRefresh = false,
  DownloadProgress? onProgress,
}) {
  return ensureGemma4Install(
    spec: spec,
    forceRefresh: forceRefresh,
    onProgress: onProgress,
  );
}

class SttBootstrap {
  static const String gemmaTranscriptionPrompt =
      'Transcribe the following speech segment in English into English text.\n'
      'Follow these specific instructions for formatting the answer:\n'
      '* Only output the transcription, with no newlines.\n'
      '* When transcribing numbers, write the digits.';

  final CactusLM lm;
  final DeviceTier tier;
  final RuntimeProfileResolver _resolveRuntimeProfile;
  final AppSupportDirectoryResolver _getAppSupportDirectory;
  final GemmaInstallHook _ensureGemmaInstall;
  final VoiceAgentDemoSettings _demoSettings;

  Future<void>? _pendingEnsureReady;

  SttBootstrap({
    CactusLM? lm,
    DeviceTier? tier,
    RuntimeProfileResolver? resolveRuntimeProfile,
    AppSupportDirectoryResolver? getAppSupportDirectory,
    GemmaInstallHook? ensureGemmaInstall,
    VoiceAgentDemoSettings? demoSettings,
  }) : lm = lm ?? CactusLM(enableToolFiltering: false),
       tier =
           tier ?? (Platform.isMacOS ? DeviceTier.desktop : DeviceTier.phone),
       _resolveRuntimeProfile =
           resolveRuntimeProfile ?? _defaultResolveRuntimeProfile,
       _getAppSupportDirectory =
           getAppSupportDirectory ?? _defaultGetAppSupportDirectory,
       _ensureGemmaInstall = ensureGemmaInstall ?? _defaultEnsureGemmaInstall,
       _demoSettings = demoSettings ?? voiceAgentDemoSettings;

  Future<void> ensureReady({StatusCb? onStatus}) {
    final pending = _pendingEnsureReady;
    if (pending != null) {
      onStatus?.call(
        'Gemma STT load already in progress. Waiting for the active attempt...',
      );
      return pending;
    }

    final future = _ensureReadyImpl(onStatus: onStatus);
    _pendingEnsureReady = future;
    future.then<void>(
      (_) {
        if (identical(_pendingEnsureReady, future)) {
          _pendingEnsureReady = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_pendingEnsureReady, future)) {
          _pendingEnsureReady = null;
        }
      },
    );
    return future;
  }

  Future<void> _ensureReadyImpl({StatusCb? onStatus}) async {
    if (lm.isLoaded()) {
      onStatus?.call('Gemma STT already ready.');
      return;
    }

    final runtimeProfile = await _resolveRuntimeProfile(tier);
    final profileLabel = _runtimeProfileLabel(runtimeProfile);
    onStatus?.call('Resolved Gemma STT runtime profile: $profileLabel.');

    if (_demoSettings.enabled) {
      await _loadDemoModel(runtimeProfile: runtimeProfile, onStatus: onStatus);
      onStatus?.call('Gemma STT ready from preloaded demo path.');
      return;
    }

    Object? lastError;
    final specs = _specsToTry(runtimeProfile);
    for (var index = 0; index < specs.length; index++) {
      final spec = specs[index];
      try {
        await _loadInstalledSpec(
          spec: spec,
          runtimeProfile: runtimeProfile,
          onStatus: onStatus,
        );
        onStatus?.call('Gemma STT ready: ${spec.slug}.');
        return;
      } catch (error) {
        lastError = error;
        if (index < specs.length - 1) {
          onStatus?.call(
            'Gemma STT failed for ${spec.slug}: $error '
            'Trying ${specs[index + 1].slug}...',
          );
        }
      }
    }

    throw Exception(
      'Gemma STT could not initialize for $profileLabel: $lastError',
    );
  }

  Future<void> _loadInstalledSpec({
    required HfGemma4Spec spec,
    required LmRuntimeProfile runtimeProfile,
    StatusCb? onStatus,
  }) async {
    final profileLabel = _runtimeProfileLabel(runtimeProfile);
    onStatus?.call('Preparing Gemma STT ${spec.slug} for $profileLabel...');
    final install = await _ensureGemmaInstall(
      spec: spec,
      onProgress: (progress, message) {
        final pct = ' (${(progress * 100).toStringAsFixed(0)}%)';
        onStatus?.call(
          'Gemma STT ${spec.slug} [$profileLabel/prepare]: $message$pct',
        );
      },
    );

    await _initializeWithContexts(
      spec: spec,
      modelPath: install.path,
      runtimeProfile: runtimeProfile,
      sourceLabel: install.usedCache ? 'cache' : 'download',
      onStatus: onStatus,
    );
  }

  Future<void> _loadDemoModel({
    required LmRuntimeProfile runtimeProfile,
    StatusCb? onStatus,
  }) async {
    final spec = _demoSettings.spec;
    final modelPath = await _resolveDemoModelPath(runtimeProfile);
    final configPath = p.join(modelPath, 'config.txt');
    if (!await Directory(modelPath).exists() ||
        !await File(configPath).exists()) {
      throw Exception(
        _buildDemoFailureMessage(
          modelPath: modelPath,
          detail: 'missing preloaded model files',
        ),
      );
    }

    try {
      await _initializeWithContexts(
        spec: spec,
        modelPath: modelPath,
        runtimeProfile: runtimeProfile,
        sourceLabel: 'demo-preload',
        onStatus: onStatus,
      );
    } catch (error) {
      throw Exception(
        _buildDemoFailureMessage(
          modelPath: modelPath,
          detail: error.toString(),
        ),
      );
    }
  }

  Future<void> _initializeWithContexts({
    required HfGemma4Spec spec,
    required String modelPath,
    required LmRuntimeProfile runtimeProfile,
    required String sourceLabel,
    StatusCb? onStatus,
  }) async {
    final contextSizes = _contextSizes(runtimeProfile);
    final profileLabel = _runtimeProfileLabel(runtimeProfile);
    Object? lastError;

    for (final contextSize in contextSizes) {
      try {
        onStatus?.call(
          'Initializing Gemma STT ${spec.slug} [$profileLabel/$sourceLabel] '
          'from $modelPath (context $contextSize)...',
        );
        await lm.initializeModel(
          params: CactusInitParams(
            model: spec.slug,
            modelPath: modelPath,
            quantization: 4,
            contextSize: contextSize,
          ),
        );
        return;
      } catch (error) {
        lastError = error;
        lm.unload();
        final suffix = contextSize == contextSizes.last
            ? ''
            : ' Retrying with a smaller context...';
        onStatus?.call(
          'Gemma STT ${spec.slug} [$profileLabel/$sourceLabel] failed at '
          'context $contextSize: $error.$suffix',
        );
      }
    }

    throw Exception(
      'Gemma STT init failed for ${spec.slug} on $profileLabel: $lastError',
    );
  }

  Future<String> transcribeFile(String path) async {
    if (!lm.isLoaded()) {
      await ensureReady();
    }

    lm.reset();
    final result = await lm.generateCompletion(
      messages: [
        ChatMessage(
          role: 'user',
          content: gemmaTranscriptionPrompt,
          audio: [path],
        ),
      ],
      params: CactusCompletionParams(
        maxTokens: 256,
        temperature: 0,
        stopSequences: const [],
      ),
    );
    if (!result.success) {
      throw Exception('STT failed: ${result.response}');
    }
    return result.response.trim();
  }

  List<int> _contextSizes(LmRuntimeProfile runtimeProfile) {
    switch (runtimeProfile) {
      case LmRuntimeProfile.desktop:
        return const [4096, 2048, 1024];
      case LmRuntimeProfile.iosDevice:
        return const [1024, 512, 256];
      case LmRuntimeProfile.iosSimulator:
        return const [512, 256];
    }
  }

  List<HfGemma4Spec> _specsToTry(LmRuntimeProfile runtimeProfile) {
    final primary = primarySpec(tier);
    if (runtimeProfile != LmRuntimeProfile.desktop) {
      return [primary];
    }
    final secondary = primary.slug == gemma4E4b.slug ? gemma4E2b : gemma4E4b;
    return [primary, secondary];
  }

  String _runtimeProfileLabel(LmRuntimeProfile runtimeProfile) {
    switch (runtimeProfile) {
      case LmRuntimeProfile.desktop:
        return 'desktop';
      case LmRuntimeProfile.iosDevice:
        return 'ios_device';
      case LmRuntimeProfile.iosSimulator:
        return 'ios_simulator';
    }
  }

  Future<String> _resolveDemoModelPath(LmRuntimeProfile runtimeProfile) async {
    switch (runtimeProfile) {
      case LmRuntimeProfile.desktop:
        return _demoSettings.desktopModelPath();
      case LmRuntimeProfile.iosSimulator:
        return _demoSettings.simulatorModelPath(_getAppSupportDirectory);
      case LmRuntimeProfile.iosDevice:
        throw Exception(
          'Demo mode only supports macOS + iOS Simulator. '
          'Use a booted simulator or disable VOICE_AGENT_DEMO_MODE.',
        );
    }
  }

  String _buildDemoFailureMessage({
    required String modelPath,
    required String detail,
  }) {
    final hostRootHint = _demoSettings.hasHostRootPath
        ? ' Host preload root: ${_demoSettings.hostRootPath}.'
        : '';
    return 'Demo mode expects a preloaded Gemma STT model at $modelPath. '
        'Run ${_demoSettings.preloadCommand} and relaunch.$hostRootHint '
        'Detail: $detail';
  }
}
