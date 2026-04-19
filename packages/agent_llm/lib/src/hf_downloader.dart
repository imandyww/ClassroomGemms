import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

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
const double _extractProgressStart = _downloadProgressWeight;
const double _extractProgressWeight = 0.09;

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
  _assertSafeModelStoragePath(root.path, purpose: 'store Gemma weights');
  if (!await root.exists()) {
    await root.create(recursive: true);
  }

  final extractedDir = Directory(p.join(root.path, spec.slug));
  _assertSafeModelStoragePath(
    extractedDir.path,
    purpose: 'extract Gemma weights',
  );
  if (await _looksExtracted(extractedDir)) {
    onProgress?.call(1.0, 'Using cached weights at ${extractedDir.path}');
    return extractedDir.path;
  }

  // Wipe any stale partial extract so we don't mix old + new files.
  if (await extractedDir.exists()) {
    await extractedDir.delete(recursive: true);
  }

  final versions = await _resolveWeightVersionCandidates(spec.hfRepo);
  debugPrint('hf_downloader: resolved $runtimeVersion -> candidates $versions');

  final zipPath = p.join(root.path, spec.weightsFilename);
  String? workingVersion;
  Object? lastError;
  for (final version in versions) {
    final url = spec.urlFor(version);
    onProgress?.call(0.0, 'Downloading ${spec.weightsFilename} ($version)...');
    try {
      await _streamDownload(url, zipPath, onProgress);
      workingVersion = version;
      break;
    } catch (e) {
      lastError = e;
      debugPrint('hf_downloader: $version failed: $e');
      // Clean up the partial zip so the next attempt starts fresh.
      try {
        final zip = File(zipPath);
        if (await zip.exists()) await zip.delete();
      } catch (_) {}
    }
  }

  if (workingVersion == null) {
    throw Exception(
      'All version candidates failed for ${spec.hfRepo}: $lastError',
    );
  }

  final version = workingVersion;
  try {
    onProgress?.call(
      _extractProgressStart,
      'Extracting ${spec.weightsFilename} on-device...',
    );
    await _extractZip(zipPath, extractedDir.path, onProgress);
    await File(
      p.join(extractedDir.path, _readyMarker),
    ).writeAsString('$version\n${spec.weightsFilename}\n');
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
      debugPrint('hf_downloader: refs HTTP ${resp.statusCode}; using main');
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
      debugPrint('hf_downloader: no tag ≤ $runtimeVersion; using main');
      return fallbackChain;
    }
    return [...compatible.map((e) => e.key), 'main'];
  } catch (e) {
    debugPrint(
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
        _extractZipFileEntry(zipPath, entry, outPath);
        processedBytes += entry.uncompressedSize;
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

void _extractZipFileEntry(String zipPath, _ZipEntryMeta entry, String outPath) {
  final input = InputFileStream(zipPath);
  try {
    input.setPosition(entry.localHeaderOffset);
    final zipFile = ZipFile(
      ZipFileHeader()
        ..compressedSize = entry.compressedSize
        ..uncompressedSize = entry.uncompressedSize,
    );
    zipFile.read(input);

    final output = OutputFileStream(outPath, bufferSize: 256 * 1024);
    try {
      zipFile.decompress(output);
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
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
