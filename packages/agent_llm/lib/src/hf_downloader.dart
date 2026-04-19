import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef DownloadProgress = void Function(double progress, String status);

/// Baked runtime cap that matches the RN sibling's `RUNTIME_VERSION` in
/// cactus-react-native@1.13.1's `modelRegistry.js`. `resolveWeightVersion`
/// picks the newest HF tag ≤ this value so the on-disk weights match the
/// format expected by the vendored `cactus.xcframework`.
const String runtimeVersion = 'v1.13.1';

const String _readyMarker = '.cactus-ready';
const double _downloadProgressWeight = 0.9;
const double _extractProgressStart = 0.95;
const double _extractProgressWeight = 0.04;

class HfGemma4Spec {
  final String slug;
  final String hfRepo;
  final String weightsFilename;

  const HfGemma4Spec({
    required this.slug,
    required this.hfRepo,
    required this.weightsFilename,
  });

  String urlFor(String version) =>
      'https://huggingface.co/$hfRepo/resolve/$version/weights/$weightsFilename';
}

const gemma4E2b = HfGemma4Spec(
  slug: 'gemma-4-e2b-it',
  hfRepo: 'Cactus-Compute/gemma-4-E2B-it',
  weightsFilename: 'gemma-4-e2b-it-int4.zip',
);

const gemma4E4b = HfGemma4Spec(
  slug: 'gemma-4-e4b-it',
  hfRepo: 'Cactus-Compute/gemma-4-E4B-it',
  weightsFilename: 'gemma-4-e4b-it-int4.zip',
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
}) async {
  final appSupport = await getApplicationSupportDirectory();
  final root = Directory(p.join(appSupport.path, 'gemma4_weights'));
  if (!await root.exists()) {
    await root.create(recursive: true);
  }

  final extractedDir = Directory(p.join(root.path, spec.slug));
  if (await _looksExtracted(extractedDir)) {
    onProgress?.call(1.0, 'Using cached weights at ${extractedDir.path}');
    return extractedDir.path;
  }

  // Wipe any stale partial extract so we don't mix old + new files.
  if (await extractedDir.exists()) {
    await extractedDir.delete(recursive: true);
  }

  final version = await _resolveWeightVersion(spec.hfRepo);
  final url = spec.urlFor(version);
  debugPrint('hf_downloader: resolved $runtimeVersion -> $version; GET $url');

  onProgress?.call(0.0, 'Downloading ${spec.weightsFilename} ($version)...');
  final zipPath = p.join(root.path, spec.weightsFilename);
  try {
    await _streamDownload(url, zipPath, onProgress);

    onProgress?.call(
      _extractProgressStart,
      'Extracting ${spec.weightsFilename} on-device...',
    );
    await _extractZip(zipPath, extractedDir.path, onProgress);
    await File(p.join(extractedDir.path, _readyMarker))
        .writeAsString('$version\n${spec.weightsFilename}\n');
  } catch (e) {
    // Best-effort cleanup of partials so a retry starts from a clean slate.
    try {
      final zip = File(zipPath);
      if (await zip.exists()) await zip.delete();
    } catch (_) {}
    try {
      if (await extractedDir.exists()) {
        await extractedDir.delete(recursive: true);
      }
    } catch (_) {}
    rethrow;
  }

  try {
    await File(zipPath).delete();
  } catch (_) {}

  onProgress?.call(1.0, 'Ready at ${extractedDir.path}');
  return extractedDir.path;
}

Future<bool> _looksExtracted(Directory dir) async {
  if (!await dir.exists()) return false;
  return File(p.join(dir.path, _readyMarker)).exists();
}

/// Port of `resolveWeightVersion` in cactus-react-native's `modelRegistry.js`.
/// Returns the newest HF tag `vX.Y(.Z)?` that is ≤ [runtimeVersion]. Falls
/// back to `'main'` if the refs endpoint is unreachable or has no compatible
/// tags — so a transient HF API failure doesn't block first-run.
Future<String> _resolveWeightVersion(String repoId) async {
  final runtime = _parseVersionTag(runtimeVersion);
  if (runtime == null) return 'main';
  try {
    final uri = Uri.parse('https://huggingface.co/api/models/$repoId/refs');
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      debugPrint('hf_downloader: refs HTTP ${resp.statusCode}; using main');
      return 'main';
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final tags = (decoded['tags'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((t) => t['name'] as String?)
        .whereType<String>()
        .toList();
    final compatible = tags
        .map((name) => MapEntry(name, _parseVersionTag(name)))
        .where((e) => e.value != null)
        .where((e) => _compareVersions(e.value!, runtime) <= 0)
        .toList()
      ..sort((a, b) => _compareVersions(b.value!, a.value!));
    if (compatible.isEmpty) {
      debugPrint('hf_downloader: no tag ≤ $runtimeVersion; using main');
      return 'main';
    }
    return compatible.first.key;
  } catch (e) {
    debugPrint('hf_downloader: resolveWeightVersion failed: $e; using main');
    return 'main';
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
    final req = http.Request('GET', Uri.parse(url));
    final resp = await client.send(req);
    if (resp.statusCode != 200) {
      throw Exception('Download failed: HTTP ${resp.statusCode} for $url');
    }
    final total = resp.contentLength ?? 0;
    final sink = File(destPath).openWrite();
    sinkRef = sink;
    var received = 0;
    var nextProgressAt = 0;
    await resp.stream.listen((chunk) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        onProgress?.call(
          (received / total) * _downloadProgressWeight,
          'Downloaded ${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      } else if (received >= nextProgressAt) {
        nextProgressAt = received + 10 * 1024 * 1024;
        onProgress?.call(
          0.0,
          'Downloaded ${(received / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      }
    }, cancelOnError: true).asFuture<void>();
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
  final isolate = await Isolate.spawn<Map<String, Object?>>(
    _extractZipEntry,
    {
      'zipPath': zipPath,
      'destDir': destDir,
      'sendPort': receivePort.sendPort,
    },
    debugName: 'gemma4-zip-extract',
  );

  final completer = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  subscription = receivePort.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'progress') {
      final stageProgress = (message['progress'] as num?)?.toDouble() ?? 0.0;
      final progress = _extractProgressStart +
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
        Exception(
          stack == null ? error : '$error\n$stack',
        ),
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

  final input = InputFileStream(zipPath);
  try {
    sendPort.send({
      'type': 'progress',
      'progress': 0.0,
      'status': 'Reading archive index...',
    });

    final archive = ZipDecoder().decodeStream(input);
    final rootFolderName = _findRootFolderName(archive);
    final totalFileBytes = _totalArchiveFileBytes(archive, rootFolderName);
    final totalBytes = totalFileBytes > 0 ? totalFileBytes : 1;
    final symlinks = <ArchiveFile>[];

    var processedBytes = 0;
    var nextProgressAt = 0.01;

    for (final file in archive) {
      if (file.isSymbolicLink) {
        symlinks.add(file);
        continue;
      }

      final rel = _relativeArchivePath(file.name, rootFolderName);
      if (rel.isEmpty) continue;

      final outPath = p.join(destDir, rel);
      if (file.isFile) {
        await Directory(p.dirname(outPath)).create(recursive: true);
        final out = OutputFileStream(outPath);
        try {
          file.writeContent(out);
        } finally {
          out.closeSync();
        }
        processedBytes += file.size;
      } else {
        await Directory(outPath).create(recursive: true);
      }

      final fraction = processedBytes / totalBytes;
      if (fraction >= nextProgressAt || processedBytes >= totalBytes) {
        sendPort.send({
          'type': 'progress',
          'progress': fraction,
          'status':
              'Extracted ${(processedBytes / 1024 / 1024).toStringAsFixed(0)} / ${(totalBytes / 1024 / 1024).toStringAsFixed(0)} MB',
        });
        nextProgressAt += 0.01;
      }
    }

    if (symlinks.isNotEmpty) {
      sendPort.send({
        'type': 'progress',
        'progress': 0.995,
        'status': 'Finalizing model links...',
      });
    }

    for (final file in symlinks) {
      final rel = _relativeArchivePath(file.name, rootFolderName);
      if (rel.isEmpty) continue;
      final linkPath = p.join(destDir, rel);
      await Link(linkPath).create(file.symbolicLink!, recursive: true);
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
  } finally {
    input.close();
  }
}

String? _findRootFolderName(Archive archive) {
  for (final file in archive) {
    final pathParts = file.name.split('/');
    if (pathParts.isNotEmpty) {
      return pathParts.first;
    }
  }
  return null;
}

int _totalArchiveFileBytes(Archive archive, String? rootFolderName) {
  var total = 0;
  for (final file in archive) {
    if (!file.isFile) continue;
    if (_relativeArchivePath(file.name, rootFolderName).isEmpty) continue;
    total += file.size;
  }
  return total;
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
