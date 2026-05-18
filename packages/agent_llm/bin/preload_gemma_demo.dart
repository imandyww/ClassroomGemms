import 'dart:io';

import 'package:agent_llm/src/hf_downloader.dart';

Future<void> main(List<String> args) async {
  String? rootArg;
  var forceRefresh = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--root':
        if (i + 1 >= args.length) {
          _usage('Missing value for --root.');
          exitCode = 64;
          return;
        }
        rootArg = args[++i];
        break;
      case '--force-refresh':
        forceRefresh = true;
        break;
      case '--help':
      case '-h':
        _usage();
        return;
      default:
        _usage('Unknown argument: $arg');
        exitCode = 64;
        return;
    }
  }

  if (rootArg == null || rootArg.trim().isEmpty) {
    _usage('Missing required --root argument.');
    exitCode = 64;
    return;
  }

  final installRoot = Directory(rootArg).absolute;

  stdout.writeln(
    'Preparing ${gemma4E2b.slug} demo weights in ${installRoot.path}...',
  );

  try {
    final environment = Gemma4InstallEnvironment(
      getEngineCompatibilityId: () async => 'host-preload',
      validateExtract: _validateHostPreloadExtract,
    );
    final result = await ensureGemma4Install(
      spec: gemma4E2b,
      installRootDirectory: installRoot,
      forceRefresh: forceRefresh,
      environment: environment,
      onProgress: (progress, status) {
        final percent = (progress * 100).toStringAsFixed(0).padLeft(3);
        stdout.writeln('[$percent%] $status');
      },
    );
    final cacheState = result.usedCache ? 'cache hit' : 'downloaded';
    stdout.writeln(
      'Ready: ${result.path} ($cacheState, quantization=int4, slug=${gemma4E2b.slug})',
    );
  } catch (error, stackTrace) {
    stderr.writeln('Failed to prepare ${gemma4E2b.slug}: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<GemmaValidationResult> _validateHostPreloadExtract(
  String modelPath,
) async {
  final dir = Directory(modelPath);
  if (!await dir.exists()) {
    return const GemmaValidationResult(
      success: false,
      message: 'extracted model directory is missing',
    );
  }

  final config = File('${dir.path}/config.txt');
  if (!await config.exists()) {
    return const GemmaValidationResult(
      success: false,
      message: 'missing config.txt',
    );
  }

  final configText = await config.readAsString();
  if (!configText.contains('model_type=gemma4')) {
    return const GemmaValidationResult(
      success: false,
      message: 'config.txt is not a Gemma 4 model config',
    );
  }

  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.weights')) {
      continue;
    }
    if (await entity.length() > 0) {
      return const GemmaValidationResult(
        success: true,
        message: 'host preload files look complete',
      );
    }
  }

  return const GemmaValidationResult(
    success: false,
    message: 'missing non-empty .weights files',
  );
}

void _usage([String? error]) {
  if (error != null) {
    stderr.writeln(error);
  }
  final sink = error == null ? stdout : stderr;
  sink.writeln(
    'Usage: flutter pub run bin/preload_gemma_demo.dart --root /abs/path/to/.demo-models [--force-refresh]',
  );
}
