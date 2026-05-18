import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:cactus/services/diagnostics.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'hf_downloader_platform_stub.dart'
    if (dart.library.ui) 'hf_downloader_platform_flutter.dart';

typedef DownloadProgress = void Function(double progress, String status);

/// Baked runtime cap that matches the RN sibling's `RUNTIME_VERSION` in
/// cactus-react-native@1.13.1's `modelRegistry.js`. `resolveWeightVersion`
/// picks the newest HF tag ≤ this value so the on-disk weights match the
/// format expected by the vendored `cactus.xcframework`.
const String runtimeVersion = 'v1.13.1';

const String _readyMarker = '.cactus-ready';
const String _readyMarkerFormat = 'gemma-ready-v2';
const String _rejectedMarkerFormat = 'gemma-rejected-v1';
const double _downloadProgressWeight = 0.9;
const double _extractProgressStart = _downloadProgressWeight;
const double _extractProgressWeight = 0.09;
const double _validationProgress = 0.995;
const int gemmaValidationContextSize = 256;
const Duration _downloadConnectTimeout = Duration(seconds: 30);
const Duration _downloadStallTimeout = Duration(seconds: 45);

class HfGemma4Spec {
  final String slug;
  final String hfRepo;
  final String weightsFilename;
  final String? appleWeightsFilename;

  const HfGemma4Spec({
    required this.slug,
    required this.hfRepo,
    required this.weightsFilename,
    this.appleWeightsFilename,
  });

  List<String> weightsFilenames({required bool preferAppleWeights}) {
    final ordered = <String>[];
    final seen = <String>{};

    void add(String? filename) {
      if (filename == null || !seen.add(filename)) {
        return;
      }
      ordered.add(filename);
    }

    if (preferAppleWeights) {
      add(appleWeightsFilename);
    }
    add(weightsFilename);
    return ordered;
  }

  String urlFor(String version, {String? weightsFilename}) {
    final archiveName = weightsFilename ?? this.weightsFilename;
    return 'https://huggingface.co/$hfRepo/resolve/$version/weights/$archiveName';
  }
}

class GemmaValidationResult {
  final bool success;
  final String message;

  const GemmaValidationResult({required this.success, required this.message});
}

class Gemma4InstallResult {
  final String path;
  final bool usedCache;

  const Gemma4InstallResult({required this.path, required this.usedCache});
}

class GemmaCompatibilityException implements Exception {
  final String message;

  const GemmaCompatibilityException(this.message);

  @override
  String toString() => 'Exception: $message';
}

class GemmaVersionMissingException implements Exception {
  final String url;

  const GemmaVersionMissingException(this.url);

  @override
  String toString() =>
      'GemmaVersionMissingException: weights zip not published at $url';
}

class GemmaReadyMarker {
  final String validatedVersion;
  final String weightsFilename;
  final String engineCompatibilityId;

  const GemmaReadyMarker({
    required this.validatedVersion,
    required this.weightsFilename,
    required this.engineCompatibilityId,
  });

  String serialize() => [
    'format=$_readyMarkerFormat',
    'validated_version=$validatedVersion',
    'weights_filename=$weightsFilename',
    'engine_compatibility_id=$engineCompatibilityId',
  ].join('\n');

  bool matches({
    required String validatedVersion,
    required String weightsFilename,
    required String engineCompatibilityId,
  }) {
    return this.validatedVersion == validatedVersion &&
        this.weightsFilename == weightsFilename &&
        this.engineCompatibilityId == engineCompatibilityId;
  }

  static GemmaReadyMarker? parse(String raw) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(raw)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) {
        return null;
      }
      values[trimmed.substring(0, separator)] = trimmed.substring(
        separator + 1,
      );
    }

    if (values['format'] != _readyMarkerFormat) {
      return null;
    }

    final validatedVersion = values['validated_version'];
    final weightsFilename = values['weights_filename'];
    final engineCompatibilityId = values['engine_compatibility_id'];
    if (validatedVersion == null ||
        weightsFilename == null ||
        engineCompatibilityId == null) {
      return null;
    }

    return GemmaReadyMarker(
      validatedVersion: validatedVersion,
      weightsFilename: weightsFilename,
      engineCompatibilityId: engineCompatibilityId,
    );
  }
}

class GemmaRejectedMarker {
  final String rejectedVersion;
  final String weightsFilename;
  final String engineCompatibilityId;
  final String failureMessage;

  const GemmaRejectedMarker({
    required this.rejectedVersion,
    required this.weightsFilename,
    required this.engineCompatibilityId,
    required this.failureMessage,
  });

  String serialize() => [
    'format=$_rejectedMarkerFormat',
    'rejected_version=$rejectedVersion',
    'weights_filename=$weightsFilename',
    'engine_compatibility_id=$engineCompatibilityId',
    'failure_message=${jsonEncode(failureMessage)}',
  ].join('\n');

  bool matches({
    required String rejectedVersion,
    required String weightsFilename,
    required String engineCompatibilityId,
  }) {
    return this.rejectedVersion == rejectedVersion &&
        this.weightsFilename == weightsFilename &&
        this.engineCompatibilityId == engineCompatibilityId;
  }

  static GemmaRejectedMarker? parse(String raw) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(raw)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) {
        return null;
      }
      values[trimmed.substring(0, separator)] = trimmed.substring(
        separator + 1,
      );
    }

    if (values['format'] != _rejectedMarkerFormat) {
      return null;
    }

    final rejectedVersion = values['rejected_version'];
    final weightsFilename = values['weights_filename'];
    final engineCompatibilityId = values['engine_compatibility_id'];
    final encodedFailureMessage = values['failure_message'];
    if (rejectedVersion == null ||
        weightsFilename == null ||
        engineCompatibilityId == null ||
        encodedFailureMessage == null) {
      return null;
    }

    try {
      final failureMessage = jsonDecode(encodedFailureMessage);
      if (failureMessage is! String) {
        return null;
      }
      return GemmaRejectedMarker(
        rejectedVersion: rejectedVersion,
        weightsFilename: weightsFilename,
        engineCompatibilityId: engineCompatibilityId,
        failureMessage: failureMessage,
      );
    } catch (_) {
      return null;
    }
  }
}

class Gemma4InstallEnvironment {
  final Future<Directory> Function() getAppSupportDirectory;
  final Future<List<String>> Function(String repoId) resolveVersions;
  final bool Function() preferAppleWeights;
  final Future<void> Function(
    String url,
    String destPath,
    DownloadProgress? onProgress,
  )
  streamDownload;
  final Future<void> Function(
    String zipPath,
    String destDir,
    DownloadProgress? onProgress,
  )
  extractZip;
  final Future<GemmaValidationResult> Function(String modelPath)
  validateExtract;
  final Future<String> Function() getEngineCompatibilityId;

  Gemma4InstallEnvironment({
    Future<Directory> Function()? getAppSupportDirectory,
    Future<List<String>> Function(String repoId)? resolveVersions,
    bool Function()? preferAppleWeights,
    Future<void> Function(
      String url,
      String destPath,
      DownloadProgress? onProgress,
    )?
    streamDownload,
    Future<void> Function(
      String zipPath,
      String destDir,
      DownloadProgress? onProgress,
    )?
    extractZip,
    Future<GemmaValidationResult> Function(String modelPath)? validateExtract,
    Future<String> Function()? getEngineCompatibilityId,
  }) : getAppSupportDirectory =
           getAppSupportDirectory ?? defaultGemmaAppSupportDirectory,
       resolveVersions = resolveVersions ?? _resolveWeightVersionCandidates,
       preferAppleWeights = preferAppleWeights ?? _defaultPreferAppleWeights,
       streamDownload = streamDownload ?? _streamDownload,
       extractZip = extractZip ?? _extractZip,
       validateExtract = validateExtract ?? _validateGemmaExtract,
       getEngineCompatibilityId =
           getEngineCompatibilityId ?? _resolveGemmaEngineCompatibilityId;
}

bool _defaultPreferAppleWeights() => Platform.isIOS || Platform.isMacOS;

Future<GemmaValidationResult> _validateGemmaExtract(String modelPath) async {
  final result = await CactusDiagnostics.validateModelPath(
    modelPath,
    contextSize: gemmaValidationContextSize,
  );
  return GemmaValidationResult(
    success: result.success,
    message: result.message,
  );
}

Future<String> _resolveGemmaEngineCompatibilityId() =>
    CactusDiagnostics.engineCompatibilityId();

const gemma4E2b = HfGemma4Spec(
  slug: 'gemma-4-e2b-it',
  hfRepo: 'Cactus-Compute/gemma-4-E2B-it',
  weightsFilename: 'gemma-4-e2b-it-int4.zip',
  appleWeightsFilename: 'gemma-4-e2b-it-int4-apple.zip',
);

const gemma4E4b = HfGemma4Spec(
  slug: 'gemma-4-e4b-it',
  hfRepo: 'Cactus-Compute/gemma-4-E4B-it',
  weightsFilename: 'gemma-4-e4b-it-int4.zip',
  appleWeightsFilename: 'gemma-4-e4b-it-int4-apple.zip',
);

/// Downloads + extracts Cactus-Compute int4 weights from HuggingFace.
/// Returns the absolute path to the extracted model directory suitable for
/// `CactusInitParams.modelPath`.
///
/// Skips work if a prior run wrote a `.cactus-ready` marker into the target
/// directory. A dir without the marker is treated as stale (partial extract)
/// and re-downloaded.
Future<String> ensureGemma4({
  required HfGemma4Spec spec,
  DownloadProgress? onProgress,
  Gemma4InstallEnvironment? environment,
  bool forceRefresh = false,
  Directory? installRootDirectory,
}) async {
  final result = await ensureGemma4Install(
    spec: spec,
    onProgress: onProgress,
    environment: environment,
    forceRefresh: forceRefresh,
    installRootDirectory: installRootDirectory,
  );
  return result.path;
}

Future<Gemma4InstallResult> ensureGemma4Install({
  required HfGemma4Spec spec,
  DownloadProgress? onProgress,
  Gemma4InstallEnvironment? environment,
  bool forceRefresh = false,
  Directory? installRootDirectory,
}) async {
  final env = environment ?? Gemma4InstallEnvironment();
  final root =
      installRootDirectory ??
      Directory(
        p.join((await env.getAppSupportDirectory()).path, 'gemma4_weights'),
      );
  _assertSafeModelStoragePath(root.path, purpose: 'store Gemma weights');
  if (!await root.exists()) {
    await root.create(recursive: true);
  }

  final extractedDir = Directory(p.join(root.path, spec.slug));
  _assertSafeModelStoragePath(
    extractedDir.path,
    purpose: 'extract Gemma weights',
  );
  final preferredWeights = spec.weightsFilenames(
    preferAppleWeights: env.preferAppleWeights(),
  );
  final readyMarker = forceRefresh
      ? null
      : await _readReadyMarker(extractedDir);
  final engineCompatibilityId = await env.getEngineCompatibilityId();
  if (readyMarker != null &&
      preferredWeights.contains(readyMarker.weightsFilename) &&
      readyMarker.matches(
        validatedVersion: readyMarker.validatedVersion,
        weightsFilename: readyMarker.weightsFilename,
        engineCompatibilityId: engineCompatibilityId,
      )) {
    await _clearRejectedMarkers(root, spec);
    onProgress?.call(1.0, 'Using cached weights at ${extractedDir.path}');
    return Gemma4InstallResult(path: extractedDir.path, usedCache: true);
  }

  final versions = await env.resolveVersions(spec.hfRepo);
  gemmaDebugLog(
    'hf_downloader: resolved $runtimeVersion -> candidates $versions',
  );

  if (forceRefresh) {
    onProgress?.call(
      0.0,
      'Force-refreshing ${spec.slug} weights at ${extractedDir.path}',
    );
    await _clearRejectedMarkers(root, spec);
  }

  // Wipe any stale partial extract so we don't mix old + new files.
  if (await extractedDir.exists()) {
    onProgress?.call(
      0.0,
      'Discarding ${forceRefresh ? "cached" : "stale"} Gemma cache at ${extractedDir.path}',
    );
    await extractedDir.delete(recursive: true);
  }

  if (forceRefresh) {
    for (final archiveName in preferredWeights) {
      final zipPath = p.join(root.path, archiveName);
      try {
        final zipFile = File(zipPath);
        if (await zipFile.exists()) {
          await zipFile.delete();
        }
      } catch (_) {}
    }
  }
  Object? lastError;
  for (final version in versions) {
    for (final archiveName in preferredWeights) {
      if (!forceRefresh) {
        final rejectedMarker = await _readRejectedMarker(
          root,
          spec,
          version,
          archiveName,
        );
        if (rejectedMarker?.matches(
              rejectedVersion: version,
              weightsFilename: archiveName,
              engineCompatibilityId: engineCompatibilityId,
            ) ==
            true) {
          lastError = GemmaCompatibilityException(
            rejectedMarker!.failureMessage,
          );
          gemmaDebugLog(
            'hf_downloader: skipping known-incompatible $version/$archiveName: '
            '${rejectedMarker.failureMessage}',
          );
          onProgress?.call(
            _validationProgress,
            'Skipping known-incompatible ${spec.slug} ($version, $archiveName)...',
          );
          continue;
        }
      }

      final url = spec.urlFor(version, weightsFilename: archiveName);
      final zipPath = p.join(root.path, archiveName);
      onProgress?.call(0.0, 'Downloading $archiveName ($version)...');
      try {
        await env.streamDownload(url, zipPath, onProgress);
        onProgress?.call(
          _extractProgressStart,
          'Extracting $archiveName on-device...',
        );
        await env.extractZip(zipPath, extractedDir.path, onProgress);
        onProgress?.call(
          _validationProgress,
          'Validating ${spec.slug} against bundled Cactus engine...',
        );
        final validation = await env.validateExtract(extractedDir.path);
        if (!validation.success) {
          throw GemmaCompatibilityException(
            'Gemma-4 weights for ${spec.slug} ($version, $archiveName) are '
            'incompatible with the bundled Cactus engine '
            '[$engineCompatibilityId]: ${validation.message}',
          );
        }
        await _writeReadyMarker(
          extractedDir,
          GemmaReadyMarker(
            validatedVersion: version,
            weightsFilename: archiveName,
            engineCompatibilityId: engineCompatibilityId,
          ),
        );
        await _clearRejectedMarkers(root, spec);
        try {
          await File(zipPath).delete();
        } catch (_) {}
        onProgress?.call(1.0, 'Ready at ${extractedDir.path}');
        return Gemma4InstallResult(path: extractedDir.path, usedCache: false);
      } catch (e) {
        lastError = e;
        gemmaDebugLog('hf_downloader: $version/$archiveName failed: $e');
        onProgress?.call(
          _validationProgress,
          'Rejected ${spec.slug} ($version, $archiveName): $e',
        );
        if (_isGemmaCompatibilityFailure(e)) {
          await _writeRejectedMarker(
            root,
            spec,
            GemmaRejectedMarker(
              rejectedVersion: version,
              weightsFilename: archiveName,
              engineCompatibilityId: engineCompatibilityId,
              failureMessage: _gemmaCompatibilityFailureMessage(e),
            ),
          );
        }
        await _cleanupGemmaInstallArtifacts(
          extractedDir: extractedDir,
          zipPath: zipPath,
        );
        if (e is! GemmaVersionMissingException &&
            !_isGemmaCompatibilityFailure(e)) {
          rethrow;
        }
      }
    }
  }

  throw Exception(
    'All version candidates failed for ${spec.hfRepo}: $lastError',
  );
}

Future<GemmaReadyMarker?> _readReadyMarker(Directory dir) async {
  if (!await dir.exists()) return null;
  final markerFile = File(p.join(dir.path, _readyMarker));
  if (!await markerFile.exists()) {
    return null;
  }

  try {
    return GemmaReadyMarker.parse(await markerFile.readAsString());
  } catch (_) {
    return null;
  }
}

bool _isGemmaCompatibilityFailure(Object error) =>
    error is GemmaCompatibilityException ||
    error.toString().contains('incompatible with the bundled Cactus engine');

String _gemmaCompatibilityFailureMessage(Object error) {
  if (error is GemmaCompatibilityException) {
    return error.message;
  }
  return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
}

Future<void> _writeReadyMarker(Directory dir, GemmaReadyMarker marker) async {
  await File(
    p.join(dir.path, _readyMarker),
  ).writeAsString('${marker.serialize()}\n');
}

String _rejectedMarkerPath(
  Directory root,
  HfGemma4Spec spec,
  String version,
  String weightsFilename,
) {
  final token = version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final archiveToken = weightsFilename.replaceAll(
    RegExp(r'[^A-Za-z0-9._-]'),
    '_',
  );
  return p.join(
    root.path,
    '.${spec.slug}.$archiveToken.$token.cactus-rejected',
  );
}

Future<GemmaRejectedMarker?> _readRejectedMarker(
  Directory root,
  HfGemma4Spec spec,
  String version,
  String weightsFilename,
) async {
  final markerFile = File(
    _rejectedMarkerPath(root, spec, version, weightsFilename),
  );
  if (!await markerFile.exists()) {
    return null;
  }

  try {
    return GemmaRejectedMarker.parse(await markerFile.readAsString());
  } catch (_) {
    return null;
  }
}

Future<void> _writeRejectedMarker(
  Directory root,
  HfGemma4Spec spec,
  GemmaRejectedMarker marker,
) async {
  await File(
    _rejectedMarkerPath(
      root,
      spec,
      marker.rejectedVersion,
      marker.weightsFilename,
    ),
  ).writeAsString('${marker.serialize()}\n');
}

Future<void> _clearRejectedMarkers(Directory root, HfGemma4Spec spec) async {
  if (!await root.exists()) {
    return;
  }

  final prefix = '.${spec.slug}.';
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.startsWith(prefix) || !name.endsWith('.cactus-rejected')) {
      continue;
    }
    try {
      await entity.delete();
    } catch (_) {}
  }
}

Future<void> _cleanupGemmaInstallArtifacts({
  required Directory extractedDir,
  required String zipPath,
}) async {
  try {
    final zip = File(zipPath);
    if (await zip.exists()) {
      await zip.delete();
    }
  } catch (_) {}
  try {
    if (await extractedDir.exists()) {
      await extractedDir.delete(recursive: true);
    }
  } catch (_) {}
}

/// Returns an ordered list of HF refs to try: the newest compatible tag
/// first, then each older compatible tag, then `'main'`. Used because the
/// Cactus team sometimes cuts a tag without uploading the weights zip for
/// every model variant — so a strict "newest tag only" policy 404s.
Future<List<String>> _resolveWeightVersionCandidates(String repoId) async {
  final runtime = _parseVersionTag(runtimeVersion);
  const fallbackChain = ['main'];
  if (runtime == null) return fallbackChain;
  try {
    final uri = Uri.parse('https://huggingface.co/api/models/$repoId/refs');
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      gemmaDebugLog('hf_downloader: refs HTTP ${resp.statusCode}; using main');
      return fallbackChain;
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final tags = (decoded['tags'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((t) => t['name'] as String?)
        .whereType<String>()
        .toList();
    final compatible =
        tags
            .map((name) => MapEntry(name, _parseVersionTag(name)))
            .where((e) => e.value != null)
            .where((e) => _compareVersions(e.value!, runtime) <= 0)
            .toList()
          ..sort((a, b) => _compareVersions(b.value!, a.value!));
    if (compatible.isEmpty) {
      gemmaDebugLog('hf_downloader: no tag <= $runtimeVersion; using main');
      return fallbackChain;
    }
    return [...compatible.map((e) => e.key), 'main'];
  } catch (e) {
    gemmaDebugLog(
      'hf_downloader: resolveWeightVersionCandidates failed: $e; using main',
    );
    return fallbackChain;
  }
}

List<int>? _parseVersionTag(String tag) {
  final m = RegExp(r'^v(\d+)\.(\d+)(?:\.(\d+))?$').firstMatch(tag);
  if (m == null) return null;
  return [
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3) ?? '0'),
  ];
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}

Future<void> _streamDownload(
  String url,
  String destPath,
  DownloadProgress? onProgress,
) async {
  final client = http.Client();
  IOSink? sinkRef;
  try {
    onProgress?.call(0.0, 'Connecting to HuggingFace...');
    final req = http.Request('GET', Uri.parse(url));
    final resp = await client.send(req).timeout(_downloadConnectTimeout);
    if (resp.statusCode == 404) {
      throw GemmaVersionMissingException(url);
    }
    if (resp.statusCode != 200) {
      throw Exception('Download failed: HTTP ${resp.statusCode} for $url');
    }
    final total = resp.contentLength ?? 0;
    final sink = File(destPath).openWrite();
    sinkRef = sink;
    var received = 0;
    var nextProgressAt = 0;
    final progressStep = total > 0
        ? max(10 * 1024 * 1024, total ~/ 100)
        : 10 * 1024 * 1024;
    await resp.stream
        .timeout(
          _downloadStallTimeout,
          onTimeout: (eventSink) {
            eventSink.addError(
              TimeoutException(
                'Gemma download stalled after '
                '${_downloadStallTimeout.inSeconds}s without receiving data.',
                _downloadStallTimeout,
              ),
            );
            eventSink.close();
          },
        )
        .listen((chunk) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            if (received < nextProgressAt && received < total) {
              return;
            }
            onProgress?.call(
              (received / total) * _downloadProgressWeight,
              'Downloaded ${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB',
            );
            while (nextProgressAt <= received && nextProgressAt < total) {
              nextProgressAt += progressStep;
            }
          } else if (received >= nextProgressAt) {
            nextProgressAt = received + progressStep;
            onProgress?.call(
              0.0,
              'Downloaded ${(received / 1024 / 1024).toStringAsFixed(1)} MB',
            );
          }
        }, cancelOnError: true)
        .asFuture<void>();
    await sink.flush();
  } finally {
    try {
      await sinkRef?.close();
    } catch (_) {}
    client.close();
  }
}

/// Streaming zip extraction. Runs in a background isolate so the Flutter UI
/// stays responsive while a multi-GB model archive is unpacked on-device.
Future<void> _extractZip(
  String zipPath,
  String destDir,
  DownloadProgress? onProgress,
) async {
  await Directory(destDir).create(recursive: true);

  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn<Map<String, Object?>>(_extractZipEntry, {
    'zipPath': zipPath,
    'destDir': destDir,
    'sendPort': receivePort.sendPort,
  }, debugName: 'gemma4-zip-extract');

  final completer = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  subscription = receivePort.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'progress') {
      final stageProgress = (message['progress'] as num?)?.toDouble() ?? 0.0;
      final progress =
          _extractProgressStart +
          (_clampUnitInterval(stageProgress) * _extractProgressWeight);
      final status =
          message['status'] as String? ?? 'Extracting model files...';
      onProgress?.call(progress, status);
      return;
    }
    if (type == 'done') {
      if (!completer.isCompleted) {
        completer.complete();
      }
      return;
    }
    if (type == 'error' && !completer.isCompleted) {
      final error = message['error'] as String? ?? 'Unknown extraction error';
      final stack = message['stack'] as String?;
      completer.completeError(
        Exception(stack == null ? error : '$error\n$stack'),
      );
    }
  });

  try {
    await completer.future;
  } finally {
    await subscription.cancel();
    receivePort.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _extractZipEntry(Map<String, Object?> args) async {
  final zipPath = args['zipPath'] as String;
  final destDir = args['destDir'] as String;
  final sendPort = args['sendPort'] as SendPort;

  try {
    sendPort.send({
      'type': 'progress',
      'progress': 0.0,
      'status': 'Reading archive index...',
    });

    final entries = _readZipEntryMetadata(zipPath);
    final rootFolderName = _findRootFolderName(entries);
    final totalFileBytes = _totalArchiveFileBytes(entries, rootFolderName);
    final totalBytes = totalFileBytes > 0 ? totalFileBytes : 1;
    final symlinks = <_ZipEntryMeta>[];

    var processedBytes = 0;
    var nextProgressAt = 0.01;
    void maybeReportProgress(int completedBytes) {
      final boundedBytes = max(0, min(completedBytes, totalBytes));
      final fraction = boundedBytes / totalBytes;
      if (fraction < nextProgressAt && boundedBytes < totalBytes) {
        return;
      }
      sendPort.send({
        'type': 'progress',
        'progress': fraction,
        'status':
            'Extracted ${(boundedBytes / 1024 / 1024).toStringAsFixed(0)} / ${(totalBytes / 1024 / 1024).toStringAsFixed(0)} MB',
      });
      while (nextProgressAt <= fraction && nextProgressAt < 1.0) {
        nextProgressAt += 0.01;
      }
    }

    for (final entry in entries) {
      if (entry.isSymlink) {
        symlinks.add(entry);
        continue;
      }

      final rel = _relativeArchivePath(entry.archivePath, rootFolderName);
      if (rel.isEmpty) continue;

      final outPath = _resolveOutputPath(destDir, rel);
      if (outPath == null) continue;

      if (entry.isDirectory) {
        await Directory(outPath).create(recursive: true);
      } else {
        await Directory(p.dirname(outPath)).create(recursive: true);
        _extractZipFileEntry(
          zipPath,
          entry,
          outPath,
          onOutputBytes: (entryBytesWritten) {
            maybeReportProgress(processedBytes + entryBytesWritten);
          },
        );
        processedBytes += entry.uncompressedSize;
      }

      maybeReportProgress(processedBytes);
    }

    if (symlinks.isNotEmpty) {
      sendPort.send({
        'type': 'progress',
        'progress': 0.995,
        'status': 'Finalizing model links...',
      });
    }

    for (final entry in symlinks) {
      final rel = _relativeArchivePath(entry.archivePath, rootFolderName);
      if (rel.isEmpty) continue;
      final linkPath = _resolveOutputPath(destDir, rel);
      if (linkPath == null) continue;

      final linkTarget = _readZipSymlinkTarget(zipPath, entry);
      if (!_isValidSymlinkTarget(destDir, linkPath, linkTarget)) {
        continue;
      }

      await Directory(p.dirname(linkPath)).create(recursive: true);
      await Link(linkPath).create(linkTarget, recursive: true);
    }

    sendPort.send({
      'type': 'progress',
      'progress': 1.0,
      'status': 'Extraction complete.',
    });
    sendPort.send({'type': 'done'});
  } catch (e, st) {
    sendPort.send({
      'type': 'error',
      'error': e.toString(),
      'stack': st.toString(),
    });
  }
}

class _ZipDirectoryInfo {
  final int offset;
  final int size;

  const _ZipDirectoryInfo({required this.offset, required this.size});
}

class _ZipEntryMeta {
  final String archivePath;
  final int localHeaderOffset;
  final int compressedSize;
  final int uncompressedSize;
  final int versionMadeBy;
  final int unixMode;

  const _ZipEntryMeta({
    required this.archivePath,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.versionMadeBy,
    required this.unixMode,
  });

  bool get isDirectory =>
      archivePath.endsWith('/') || archivePath.endsWith('\\');

  bool get isSymlink {
    if (isDirectory || (versionMadeBy >> 8) != 3) {
      return false;
    }
    return (unixMode & 0xf000) == 0xa000;
  }
}

List<_ZipEntryMeta> _readZipEntryMetadata(String zipPath) {
  final input = InputFileStream(zipPath);
  try {
    final directoryInfo = _readZipDirectoryInfo(input);
    final dirContent = input.subset(
      position: directoryInfo.offset,
      length: directoryInfo.size,
      bufferSize: min(directoryInfo.size, 1024),
    );

    final entries = <_ZipEntryMeta>[];
    while (!dirContent.isEOS) {
      final signature = dirContent.readUint32();
      if (signature != ZipFileHeader.signature) break;

      final header = ZipFileHeader()..read(dirContent);
      entries.add(
        _ZipEntryMeta(
          archivePath: header.filename,
          localHeaderOffset: header.localHeaderOffset,
          compressedSize: header.compressedSize,
          uncompressedSize: header.uncompressedSize,
          versionMadeBy: header.versionMadeBy,
          unixMode: header.externalFileAttributes >> 16,
        ),
      );
    }

    return entries;
  } finally {
    input.closeSync();
  }
}

_ZipDirectoryInfo _readZipDirectoryInfo(InputFileStream input) {
  final eocdOffset = _findEndOfCentralDirectoryOffset(input);
  if (eocdOffset < 0) {
    throw Exception('Could not find zip end-of-central-directory record.');
  }

  input.setPosition(eocdOffset);
  final signature = input.readUint32();
  if (signature != ZipDirectory.eocdSignature) {
    throw Exception('Invalid zip end-of-central-directory signature.');
  }

  input.readUint16(); // numberOfThisDisk
  input.readUint16(); // diskWithTheStartOfTheCentralDirectory
  input.readUint16(); // totalCentralDirectoryEntriesOnThisDisk
  input.readUint16(); // totalCentralDirectoryEntries
  var centralDirectorySize = input.readUint32();
  var centralDirectoryOffset = input.readUint32();

  final commentLength = input.readUint16();
  if (commentLength > 0) {
    input.readString(size: commentLength, utf8: false);
  }

  final zip64LocatorOffset = eocdOffset - ZipDirectory.zip64EocdLocatorSize;
  if (zip64LocatorOffset >= 0) {
    final zip64 = input.subset(
      position: zip64LocatorOffset,
      length: ZipDirectory.zip64EocdLocatorSize,
    );
    final zip64Signature = zip64.readUint32();
    if (zip64Signature == ZipDirectory.zip64EocdLocatorSignature) {
      zip64.readUint32(); // start disk
      final zip64DirectoryOffset = zip64.readUint64();
      zip64.readUint32(); // disk count

      input.setPosition(zip64DirectoryOffset);
      if (input.readUint32() == ZipDirectory.zip64EocdSignature) {
        input.readUint64(); // record size
        input.readUint16(); // version made by
        input.readUint16(); // version needed
        input.readUint32(); // disk number
        input.readUint32(); // start disk
        input.readUint64(); // entries on disk
        input.readUint64(); // total entries
        centralDirectorySize = input.readUint64();
        centralDirectoryOffset = input.readUint64();
      }
    }
  }

  return _ZipDirectoryInfo(
    offset: centralDirectoryOffset,
    size: centralDirectorySize,
  );
}

int _findEndOfCentralDirectoryOffset(InputFileStream input) {
  if (input.length <= 4) {
    return -1;
  }

  final originalPosition = input.position;
  final length = input.length - 4;
  const bufferSize = 1024;
  final chunkSize = min(length, bufferSize);

  var startPos = length - chunkSize;
  while (startPos >= 0) {
    input.setPosition(startPos);
    final chunk = InputMemoryStream(input.readBytes(chunkSize).toUint8List());
    for (var chunkPos = chunkSize - 4; chunkPos >= 0; --chunkPos) {
      chunk.setPosition(chunkPos);
      if (chunk.readUint32() == ZipDirectory.eocdSignature) {
        input.setPosition(originalPosition);
        return startPos + chunkPos;
      }
    }

    if (startPos > 0 && startPos < chunkSize) {
      startPos = 0;
    } else {
      startPos -= chunkSize;
    }
  }

  input.setPosition(originalPosition);
  return -1;
}

String? _findRootFolderName(List<_ZipEntryMeta> entries) {
  if (entries.isEmpty) return null;

  String? candidate;
  for (final entry in entries) {
    final normalizedPath = entry.archivePath.replaceAll('\\', '/');
    final slashIndex = normalizedPath.indexOf('/');
    if (slashIndex <= 0) {
      return null;
    }
    final root = normalizedPath.substring(0, slashIndex);
    candidate ??= root;
    if (root != candidate) {
      return null;
    }
  }
  return candidate;
}

int _totalArchiveFileBytes(
  List<_ZipEntryMeta> entries,
  String? rootFolderName,
) {
  var total = 0;
  for (final entry in entries) {
    if (entry.isDirectory || entry.isSymlink) continue;
    if (_relativeArchivePath(entry.archivePath, rootFolderName).isEmpty) {
      continue;
    }
    total += entry.uncompressedSize;
  }
  return total;
}

// The archive package's ZLibDecoder.decodeStream accumulates every decoded
// chunk into a list and only flushes on close(), so unpacking a multi-GB
// weight file holds the entire decompressed payload in RAM and OOMs iOS
// mid-extract. We bypass it by reading the local file header ourselves and
// piping the compressed payload through dart:io's native ZLibCodec with a
// sink that writes each decoded chunk straight to disk.
void _extractZipFileEntry(
  String zipPath,
  _ZipEntryMeta entry,
  String outPath, {
  void Function(int outputBytes)? onOutputBytes,
}) {
  final raf = File(zipPath).openSync();
  try {
    raf.setPositionSync(entry.localHeaderOffset);
    final header = raf.readSync(30);
    if (header.length < 30) {
      throw Exception(
        'Truncated zip local file header at ${entry.localHeaderOffset}.',
      );
    }
    final hd = ByteData.sublistView(header);
    if (hd.getUint32(0, Endian.little) != 0x04034b50) {
      throw Exception(
        'Invalid zip local file header signature for ${entry.archivePath}.',
      );
    }
    final flags = hd.getUint16(6, Endian.little);
    if ((flags & 0x1) != 0) {
      throw Exception(
        'Encrypted zip entries are not supported (${entry.archivePath}).',
      );
    }
    final compressionMethod = hd.getUint16(8, Endian.little);
    final fnLen = hd.getUint16(26, Endian.little);
    final exLen = hd.getUint16(28, Endian.little);
    raf.setPositionSync(entry.localHeaderOffset + 30 + fnLen + exLen);

    final out = File(outPath).openSync(mode: FileMode.write);
    try {
      late final int outputBytes;
      if (compressionMethod == 0) {
        outputBytes = _streamCopyBytes(
          raf,
          out,
          entry.compressedSize,
          onOutputBytes: onOutputBytes,
        );
      } else if (compressionMethod == 8) {
        outputBytes = _streamInflateBytes(
          raf,
          out,
          entry.compressedSize,
          onOutputBytes: onOutputBytes,
        );
      } else {
        throw UnsupportedError(
          'Unsupported zip compression method $compressionMethod '
          'for ${entry.archivePath}.',
        );
      }
      if (outputBytes != entry.uncompressedSize) {
        throw Exception(
          'Zip extraction produced $outputBytes / ${entry.uncompressedSize} '
          'bytes for ${entry.archivePath}.',
        );
      }
    } finally {
      out.closeSync();
    }
  } finally {
    raf.closeSync();
  }
}

int _streamCopyBytes(
  RandomAccessFile input,
  RandomAccessFile output,
  int length, {
  void Function(int outputBytes)? onOutputBytes,
}) {
  final buffer = Uint8List(1024 * 1024);
  var remaining = length;
  var written = 0;
  while (remaining > 0) {
    final toRead = remaining < buffer.length ? remaining : buffer.length;
    final n = input.readIntoSync(buffer, 0, toRead);
    if (n <= 0) {
      throw Exception('Unexpected EOF while copying stored zip entry.');
    }
    output.writeFromSync(buffer, 0, n);
    remaining -= n;
    written += n;
    onOutputBytes?.call(written);
  }
  return written;
}

int _streamInflateBytes(
  RandomAccessFile input,
  RandomAccessFile output,
  int compressedSize, {
  void Function(int outputBytes)? onOutputBytes,
}) {
  final outSink = _RafByteSink(output, onWrite: onOutputBytes);
  final inSink = ZLibCodec(raw: true).decoder.startChunkedConversion(outSink);
  final buffer = Uint8List(1024 * 1024);
  var remaining = compressedSize;
  var closed = false;
  try {
    while (remaining > 0) {
      final toRead = remaining < buffer.length ? remaining : buffer.length;
      final n = input.readIntoSync(buffer, 0, toRead);
      if (n <= 0) {
        throw Exception('Unexpected EOF while reading compressed zip entry.');
      }
      inSink.add(Uint8List.sublistView(buffer, 0, n));
      remaining -= n;
    }
    inSink.close();
    closed = true;
  } finally {
    if (!closed) {
      try {
        inSink.close();
      } catch (_) {}
    }
  }
  return outSink.bytesWritten;
}

class _RafByteSink implements Sink<List<int>> {
  final RandomAccessFile _file;
  final void Function(int outputBytes)? _onWrite;
  var _bytesWritten = 0;

  _RafByteSink(this._file, {void Function(int outputBytes)? onWrite})
    : _onWrite = onWrite;

  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    if (data is Uint8List) {
      _file.writeFromSync(data);
    } else {
      _file.writeFromSync(Uint8List.fromList(data));
    }
    _bytesWritten += data.length;
    _onWrite?.call(_bytesWritten);
  }

  @override
  void close() {
    // Caller owns the underlying file handle.
  }

  int get bytesWritten => _bytesWritten;
}

String _readZipSymlinkTarget(String zipPath, _ZipEntryMeta entry) {
  final input = InputFileStream(zipPath);
  try {
    input.setPosition(entry.localHeaderOffset);
    final zipFile = ZipFile(
      ZipFileHeader()
        ..compressedSize = entry.compressedSize
        ..uncompressedSize = entry.uncompressedSize,
    );
    zipFile.read(input);
    return utf8.decode(zipFile.getStream().toUint8List());
  } finally {
    input.closeSync();
  }
}

String? _resolveOutputPath(String destDir, String relativePath) {
  final normalizedRelative = p.normalize(relativePath);
  if (normalizedRelative.isEmpty || normalizedRelative == '.') {
    return null;
  }

  final outputPath = p.normalize(p.join(destDir, normalizedRelative));
  final normalizedRoot = p.normalize(destDir);
  if (outputPath == normalizedRoot || p.isWithin(normalizedRoot, outputPath)) {
    return outputPath;
  }
  return null;
}

bool _isValidSymlinkTarget(
  String outputRoot,
  String linkPath,
  String targetPath,
) {
  if (targetPath.isEmpty || p.isAbsolute(targetPath)) {
    return false;
  }

  final resolvedTarget = p.normalize(p.join(p.dirname(linkPath), targetPath));
  final normalizedRoot = p.normalize(outputRoot);
  return resolvedTarget == normalizedRoot ||
      p.isWithin(normalizedRoot, resolvedTarget);
}

String _relativeArchivePath(String archivePath, String? rootFolderName) {
  if (rootFolderName != null && archivePath.startsWith('$rootFolderName/')) {
    return archivePath.substring(rootFolderName.length + 1);
  }
  return archivePath;
}

double _clampUnitInterval(double value) {
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

void _assertSafeModelStoragePath(String targetPath, {required String purpose}) {
  var cursor = p.normalize(targetPath);
  while (true) {
    final hasPubspec = File(p.join(cursor, 'pubspec.yaml')).existsSync();
    final hasMetadata = File(p.join(cursor, '.metadata')).existsSync();
    if (hasPubspec && hasMetadata) {
      throw StateError(
        'Refusing to $purpose inside Flutter project tree: $targetPath '
        '(project root: $cursor)',
      );
    }

    final parent = p.dirname(cursor);
    if (parent == cursor) {
      break;
    }
    cursor = parent;
  }
}
