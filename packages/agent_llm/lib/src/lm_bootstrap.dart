import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'demo_mode.dart';
import 'hf_downloader.dart';
import 'model_picker.dart';

typedef StatusCb = void Function(String message);
typedef RuntimeProfileResolver =
    Future<LmRuntimeProfile> Function(DeviceTier tier);
typedef AppSupportDirectoryResolver = Future<Directory> Function();
typedef GemmaInstallHook =
    Future<Gemma4InstallResult> Function({
      required HfGemma4Spec spec,
      bool forceRefresh,
      DownloadProgress? onProgress,
    });
typedef ModelPathValidator =
    Future<GemmaValidationResult> Function(
      String modelPath, {
      required int contextSize,
    });

enum LmRuntimeProfile { desktop, iosDevice, iosSimulator }

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

Future<GemmaValidationResult> _defaultValidateModelPath(
  String modelPath, {
  required int contextSize,
}) async {
  final validation = await CactusDiagnostics.validateModelPath(
    modelPath,
    contextSize: contextSize,
  );
  return GemmaValidationResult(
    success: validation.success,
    message: validation.message,
  );
}

Future<Directory> _defaultGetAppSupportDirectory() =>
    getApplicationSupportDirectory();

class _GemmaInitAttemptResult {
  final int? successfulContext;
  final Object? lastError;

  const _GemmaInitAttemptResult.success(this.successfulContext)
    : lastError = null;

  const _GemmaInitAttemptResult.failure(this.lastError)
    : successfulContext = null;

  bool get isSuccess => successfulContext != null;
}

class LmBootstrap {
  final CactusLM lm;
  final DeviceTier tier;
  final RuntimeProfileResolver _resolveRuntimeProfile;
  final AppSupportDirectoryResolver _getAppSupportDirectory;
  final GemmaInstallHook _ensureGemmaInstall;
  final ModelPathValidator _validateModelPath;
  final VoiceAgentDemoSettings _demoSettings;
  Future<PickedModel>? _pendingEnsureReady;

  LmBootstrap({
    required this.tier,
    CactusLM? lm,
    RuntimeProfileResolver? resolveRuntimeProfile,
    AppSupportDirectoryResolver? getAppSupportDirectory,
    GemmaInstallHook? ensureGemmaInstall,
    ModelPathValidator? validateModelPath,
    VoiceAgentDemoSettings? demoSettings,
  }) : lm = lm ?? CactusLM(enableToolFiltering: false),
       _resolveRuntimeProfile =
           resolveRuntimeProfile ?? _defaultResolveRuntimeProfile,
       _getAppSupportDirectory =
           getAppSupportDirectory ?? _defaultGetAppSupportDirectory,
       _ensureGemmaInstall = ensureGemmaInstall ?? _defaultEnsureGemmaInstall,
       _validateModelPath = validateModelPath ?? _defaultValidateModelPath,
       _demoSettings = demoSettings ?? voiceAgentDemoSettings;

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

  String _describeGemmaFailure(Object error) {
    final message = error.toString();
    if (message.contains('incompatible with the bundled Cactus engine')) {
      return message;
    }
    return 'Gemma-4 init failed: $message';
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

  List<HfGemma4Spec> _specsToTry(LmRuntimeProfile runtimeProfile) {
    final primary = primarySpec(tier);
    if (runtimeProfile != LmRuntimeProfile.desktop) {
      return [primary];
    }

    final secondary = primary.slug == gemma4E4b.slug ? gemma4E2b : gemma4E4b;
    return [primary, secondary];
  }

  String _pickedModelSourceLabel(bool isPrimarySpec) {
    return isPrimarySpec
        ? 'HuggingFace int4'
        : 'HuggingFace int4 (sibling fallback)';
  }

  bool _usesRegistryFallback() => tier == DeviceTier.desktop;

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
    return 'Demo mode expects a preloaded ${_demoSettings.spec.slug} model '
        'at $modelPath. Run ${_demoSettings.preloadCommand} and relaunch.'
        '$hostRootHint Detail: $detail';
  }

  Future<PickedModel> _loadDemoModel({
    required LmRuntimeProfile runtimeProfile,
    StatusCb? onStatus,
  }) async {
    final spec = _demoSettings.spec;
    final modelPath = await _resolveDemoModelPath(runtimeProfile);
    final contextSizes = _contextSizes(runtimeProfile);
    final validationContext = contextSizes.last;

    onStatus?.call(
      'Demo mode: validating preloaded ${spec.slug} at $modelPath...',
    );
    final validation = await _validateModelPath(
      modelPath,
      contextSize: validationContext,
    );
    if (!validation.success) {
      throw Exception(
        _buildDemoFailureMessage(
          modelPath: modelPath,
          detail:
              'validation failed at context $validationContext: '
              '${validation.message}',
        ),
      );
    }

    final initAttempt = await _initializeGemmaWithContexts(
      spec: spec,
      modelPath: modelPath,
      sourceLabel: 'demo-preload',
      runtimeProfile: runtimeProfile,
      contextSizes: contextSizes,
      onStatus: onStatus,
    );
    if (!initAttempt.isSuccess) {
      throw Exception(
        _buildDemoFailureMessage(
          modelPath: modelPath,
          detail: _describeGemmaFailure(
            initAttempt.lastError ?? Exception('unknown init error'),
          ),
        ),
      );
    }

    return PickedModel(
      slug: spec.slug,
      modelPath: modelPath,
      quantization: 4,
      sourceLabel: _demoSettings.sourceLabel,
    );
  }

  Future<_GemmaInitAttemptResult> _initializeGemmaWithContexts({
    required HfGemma4Spec spec,
    required String modelPath,
    required String sourceLabel,
    required LmRuntimeProfile runtimeProfile,
    required List<int> contextSizes,
    StatusCb? onStatus,
  }) async {
    Object? lastInitError;
    final profileLabel = _runtimeProfileLabel(runtimeProfile);

    for (final ctxSize in contextSizes) {
      try {
        onStatus?.call(
          'Initializing ${spec.slug} [$profileLabel/$sourceLabel] from '
          '$modelPath (context $ctxSize)...',
        );
        await lm.initializeModel(
          params: CactusInitParams(
            model: spec.slug,
            modelPath: modelPath,
            quantization: 4,
            contextSize: ctxSize,
          ),
        );
        return _GemmaInitAttemptResult.success(ctxSize);
      } catch (e) {
        lastInitError = e;
        final suffix = ctxSize == contextSizes.last
            ? ''
            : ' Retrying with a smaller context...';
        onStatus?.call(
          '${spec.slug} [$profileLabel/$sourceLabel] failed at context '
          '$ctxSize: $e.$suffix',
        );
      }
    }

    return _GemmaInitAttemptResult.failure(lastInitError);
  }

  Future<PickedModel> _loadGemmaSpec({
    required HfGemma4Spec spec,
    required LmRuntimeProfile runtimeProfile,
    required bool isPrimarySpec,
    StatusCb? onStatus,
  }) async {
    final profileLabel = _runtimeProfileLabel(runtimeProfile);
    final contextSizes = _contextSizes(runtimeProfile);

    Gemma4InstallResult install;
    onStatus?.call('Preparing ${spec.slug} for $profileLabel...');
    install = await _ensureGemmaInstall(
      spec: spec,
      onProgress: (progress, message) {
        onStatus?.call(
          '${spec.slug} [$profileLabel/prepare]: $message '
          '(${(progress * 100).toStringAsFixed(0)}%)',
        );
      },
    );

    final initialSource = install.usedCache ? 'cache' : 'download';
    final initialAttempt = await _initializeGemmaWithContexts(
      spec: spec,
      modelPath: install.path,
      sourceLabel: initialSource,
      runtimeProfile: runtimeProfile,
      contextSizes: contextSizes,
      onStatus: onStatus,
    );
    if (initialAttempt.isSuccess) {
      return PickedModel(
        slug: spec.slug,
        modelPath: install.path,
        quantization: 4,
        sourceLabel: _pickedModelSourceLabel(isPrimarySpec),
      );
    }

    if (install.usedCache) {
      final validationContext = contextSizes.last;
      onStatus?.call(
        'Validating cached ${spec.slug} [$profileLabel/cache] at context '
        '$validationContext after init failure: ${initialAttempt.lastError}',
      );
      final validation = await _validateModelPath(
        install.path,
        contextSize: validationContext,
      );
      if (!validation.success) {
        onStatus?.call(
          'Cached ${spec.slug} [$profileLabel/cache] failed validation at '
          'context $validationContext: ${validation.message}. '
          'Refreshing weights once...',
        );
        install = await _ensureGemmaInstall(
          spec: spec,
          forceRefresh: true,
          onProgress: (progress, message) {
            onStatus?.call(
              '${spec.slug} [$profileLabel/refresh]: $message '
              '(${(progress * 100).toStringAsFixed(0)}%)',
            );
          },
        );

        final refreshedAttempt = await _initializeGemmaWithContexts(
          spec: spec,
          modelPath: install.path,
          sourceLabel: 'refresh',
          runtimeProfile: runtimeProfile,
          contextSizes: contextSizes,
          onStatus: onStatus,
        );
        if (refreshedAttempt.isSuccess) {
          return PickedModel(
            slug: spec.slug,
            modelPath: install.path,
            quantization: 4,
            sourceLabel: _pickedModelSourceLabel(isPrimarySpec),
          );
        }

        throw Exception(
          'Gemma-4 init failed for ${spec.slug} on $profileLabel after '
          'forced refresh: ${refreshedAttempt.lastError}',
        );
      }

      throw Exception(
        'Gemma-4 init failed for ${spec.slug} on $profileLabel despite '
        'cached validation success at context $validationContext: '
        '${initialAttempt.lastError}',
      );
    }

    throw Exception(
      'Gemma-4 init failed for ${spec.slug} on $profileLabel from '
      '$initialSource weights: ${initialAttempt.lastError}',
    );
  }

  /// Try gemma-4 int4 via the vendored modelPath bypass.
  ///
  /// Order of attempts:
  ///   1. Resolve a runtime profile once (desktop, ios_device, ios_simulator)
  ///   2. Try the primary HF spec for that profile (E4B on desktop, E2B on iOS)
  ///   3. Desktop only: try the sibling spec if the primary fails
  ///   4. Desktop only: fall back to qwen3-1.7 from the stock Cactus registry
  Future<PickedModel> ensureReady({StatusCb? onStatus}) {
    final pending = _pendingEnsureReady;
    if (pending != null) {
      onStatus?.call(
        'Model load already in progress. Waiting for the active attempt...',
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

  Future<PickedModel> _ensureReadyImpl({StatusCb? onStatus}) async {
    final runtimeProfile = await _resolveRuntimeProfile(tier);
    final profileLabel = _runtimeProfileLabel(runtimeProfile);
    if (_demoSettings.enabled) {
      onStatus?.call(
        'Resolved Gemma runtime profile: $profileLabel (demo mode).',
      );
      final pickedModel = await _loadDemoModel(
        runtimeProfile: runtimeProfile,
        onStatus: onStatus,
      );
      onStatus?.call('Loaded ${pickedModel.slug} from preloaded demo path.');
      return pickedModel;
    }

    final specs = _specsToTry(runtimeProfile);
    Object? lastSpecFailure;
    HfGemma4Spec? lastSpec;

    onStatus?.call('Resolved Gemma runtime profile: $profileLabel.');

    for (var index = 0; index < specs.length; index++) {
      final spec = specs[index];
      lastSpec = spec;
      try {
        final pickedModel = await _loadGemmaSpec(
          spec: spec,
          runtimeProfile: runtimeProfile,
          isPrimarySpec: index == 0,
          onStatus: onStatus,
        );
        onStatus?.call('Loaded ${spec.slug} for $profileLabel.');
        return pickedModel;
      } catch (e, st) {
        lastSpecFailure = e;
        debugPrint('${spec.slug} load failed for $profileLabel: $e\n$st');
        final failureMessage = _describeGemmaFailure(e);
        if (index < specs.length - 1) {
          onStatus?.call(
            '$failureMessage Trying ${specs[index + 1].slug} on '
            '$profileLabel...',
          );
        } else {
          if (_usesRegistryFallback()) {
            onStatus?.call('$failureMessage Falling back to $fallbackSlug.');
          } else {
            onStatus?.call(
              '$failureMessage iOS stays pinned to ${gemma4E2b.slug}; '
              'not falling back to $fallbackSlug.',
            );
          }
        }
      }
    }

    if (!_usesRegistryFallback()) {
      final failedSpec = lastSpec ?? primarySpec(tier);
      final failureMessage = lastSpecFailure == null
          ? 'Gemma-4 init failed for ${failedSpec.slug} on $profileLabel.'
          : _describeGemmaFailure(lastSpecFailure);
      throw Exception(
        '$failureMessage ${failedSpec.slug} is the only model supported on iOS.',
      );
    }

    await lm.downloadModel(
      model: fallbackSlug,
      downloadProcessCallback: (progress, msg, isError) {
        if (progress != null) {
          onStatus?.call(
            'Fallback dl: $msg (${(progress * 100).toStringAsFixed(0)}%)',
          );
        } else {
          onStatus?.call('Fallback dl: $msg');
        }
      },
    );
    await lm.initializeModel(params: CactusInitParams(model: fallbackSlug));
    onStatus?.call('Loaded fallback $fallbackSlug.');
    return PickedModel(
      slug: fallbackSlug,
      sourceLabel: 'Cactus Supabase fallback',
      isFallback: true,
    );
  }
}
