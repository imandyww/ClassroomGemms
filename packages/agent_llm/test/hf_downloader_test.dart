import 'dart:io';
import 'dart:typed_data';

import 'package:agent_llm/agent_llm.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('GemmaReadyMarker', () {
    test('matches only identical version, weights, and engine id', () {
      const marker = GemmaReadyMarker(
        validatedVersion: 'v1.13.1',
        weightsFilename: 'gemma-4-e2b-it-int4.zip',
        engineCompatibilityId: 'engine-a',
      );

      expect(
        marker.matches(
          validatedVersion: 'v1.13.1',
          weightsFilename: 'gemma-4-e2b-it-int4.zip',
          engineCompatibilityId: 'engine-a',
        ),
        isTrue,
      );
      expect(
        marker.matches(
          validatedVersion: 'v1.12.0',
          weightsFilename: 'gemma-4-e2b-it-int4.zip',
          engineCompatibilityId: 'engine-a',
        ),
        isFalse,
      );
      expect(
        marker.matches(
          validatedVersion: 'v1.13.1',
          weightsFilename: 'gemma-4-e4b-it-int4.zip',
          engineCompatibilityId: 'engine-a',
        ),
        isFalse,
      );
      expect(
        marker.matches(
          validatedVersion: 'v1.13.1',
          weightsFilename: 'gemma-4-e2b-it-int4.zip',
          engineCompatibilityId: 'engine-b',
        ),
        isFalse,
      );
      expect(
        GemmaReadyMarker.parse('v1.13\ngemma-4-e2b-it-int4.zip\n'),
        isNull,
      );
    });
  });

  test('ensureGemma4 retries older refs after validation failure', () async {
    final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final downloadedVersions = <String>[];
    var validationCall = 0;
    final environment = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-a',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['v1.13.1', 'v1.12.0'],
      streamDownload: (url, destPath, _) async {
        downloadedVersions.add(url.split('/resolve/')[1].split('/').first);
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, onProgress) async {
        expect(onProgress, isNull);
        final dest = Directory(destDir);
        await dest.create(recursive: true);
        final staleSentinel = File(p.join(destDir, 'stale.txt'));
        if (validationCall == 1) {
          expect(await staleSentinel.exists(), isFalse);
        }
        await staleSentinel.writeAsString('attempt:$validationCall');
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (modelPath) async {
        final staleSentinel = File(p.join(modelPath, 'stale.txt'));
        final contents = await staleSentinel.readAsString();
        if (validationCall == 0) {
          expect(contents, 'attempt:0');
          validationCall++;
          return const GemmaValidationResult(
            success: false,
            message: 'bad header',
          );
        }

        expect(contents, 'attempt:1');
        return const GemmaValidationResult(
          success: true,
          message: 'Context initialized successfully',
        );
      },
    );

    final path = await ensureGemma4(spec: gemma4E2b, environment: environment);

    expect(downloadedVersions, ['v1.13.1', 'v1.12.0']);
    expect(path, p.join(tempRoot.path, 'gemma4_weights', gemma4E2b.slug));

    final marker = GemmaReadyMarker.parse(
      await File(p.join(path, '.cactus-ready')).readAsString(),
    );
    expect(marker, isNotNull);
    expect(marker!.validatedVersion, 'v1.12.0');
    expect(marker.weightsFilename, gemma4E2b.weightsFilename);
    expect(marker.engineCompatibilityId, 'engine-a');
  });

  test('ensureGemma4 forceRefresh ignores matching cache markers', () async {
    final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final extractedDir = Directory(
      p.join(tempRoot.path, 'gemma4_weights', gemma4E2b.slug),
    );
    await extractedDir.create(recursive: true);
    await File(p.join(extractedDir.path, 'old.txt')).writeAsString('stale');
    await File(p.join(extractedDir.path, '.cactus-ready')).writeAsString(
      const GemmaReadyMarker(
        validatedVersion: 'v1.13.1',
        weightsFilename: 'gemma-4-e2b-it-int4.zip',
        engineCompatibilityId: 'engine-a',
      ).serialize(),
    );

    var downloadCalls = 0;
    var validateCalls = 0;
    final environment = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-a',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['v1.13.1'],
      streamDownload: (_, destPath, _) async {
        downloadCalls++;
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, _) async {
        expect(await File(p.join(destDir, 'old.txt')).exists(), isFalse);
        await Directory(destDir).create(recursive: true);
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (_) async {
        validateCalls++;
        return const GemmaValidationResult(success: true, message: 'ok');
      },
    );

    final result = await ensureGemma4Install(
      spec: gemma4E2b,
      environment: environment,
      forceRefresh: true,
    );

    expect(result.path, extractedDir.path);
    expect(result.usedCache, isFalse);
    expect(downloadCalls, 1);
    expect(validateCalls, 1);
  });

  test(
    'ensureGemma4Install writes into a caller-supplied install root and reuses cache markers',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final installRoot = Directory(p.join(tempRoot.path, '.demo-models'));
      var downloadCalls = 0;
      var validateCalls = 0;
      final environment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => false,
        resolveVersions: (_) async => ['v1.13.1'],
        streamDownload: (_, destPath, _) async {
          downloadCalls++;
          await File(destPath).writeAsString('zip');
        },
        extractZip: (_, destDir, _) async {
          await Directory(destDir).create(recursive: true);
          await File(
            p.join(destDir, 'config.txt'),
          ).writeAsString('model_type=gemma4');
        },
        validateExtract: (_) async {
          validateCalls++;
          return const GemmaValidationResult(success: true, message: 'ok');
        },
      );

      final first = await ensureGemma4Install(
        spec: gemma4E2b,
        environment: environment,
        installRootDirectory: installRoot,
      );
      final second = await ensureGemma4Install(
        spec: gemma4E2b,
        environment: environment,
        installRootDirectory: installRoot,
      );

      expect(first.path, p.join(installRoot.path, gemma4E2b.slug));
      expect(first.usedCache, isFalse);
      expect(second.path, p.join(installRoot.path, gemma4E2b.slug));
      expect(second.usedCache, isTrue);
      expect(downloadCalls, 1);
      expect(validateCalls, 1);
      expect(await File(p.join(first.path, '.cactus-ready')).exists(), isTrue);
    },
  );

  test(
    'ensureGemma4Install reuses a ready cache without resolving remote versions again',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final installRoot = Directory(p.join(tempRoot.path, '.demo-models'));
      final installEnvironment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => false,
        resolveVersions: (_) async => ['v1.13.1'],
        streamDownload: (_, destPath, _) async {
          await File(destPath).writeAsString('zip');
        },
        extractZip: (_, destDir, _) async {
          await Directory(destDir).create(recursive: true);
          await File(
            p.join(destDir, 'config.txt'),
          ).writeAsString('model_type=gemma4');
        },
        validateExtract: (_) async =>
            const GemmaValidationResult(success: true, message: 'ok'),
      );

      final first = await ensureGemma4Install(
        spec: gemma4E2b,
        environment: installEnvironment,
        installRootDirectory: installRoot,
      );

      final cachedEnvironment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => false,
        resolveVersions: (_) async =>
            fail('resolveVersions should not run on a cache hit'),
        streamDownload: (url, destPath, onProgress) async =>
            fail('streamDownload should not run on a cache hit'),
        extractZip: (zipPath, destDir, onProgress) async =>
            fail('extractZip should not run on a cache hit'),
        validateExtract: (_) async =>
            fail('validateExtract should not run on a cache hit'),
      );

      final second = await ensureGemma4Install(
        spec: gemma4E2b,
        environment: cachedEnvironment,
        installRootDirectory: installRoot,
      );

      expect(first.usedCache, isFalse);
      expect(second.path, first.path);
      expect(second.usedCache, isTrue);
    },
  );

  test('ensureGemma4 remembers incompatible refs for the same engine', () async {
    final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    var downloadCalls = 0;
    var validateCalls = 0;
    final environment = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-a',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['main'],
      streamDownload: (_, destPath, _) async {
        downloadCalls++;
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, _) async {
        await Directory(destDir).create(recursive: true);
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (_) async {
        validateCalls++;
        return const GemmaValidationResult(
          success: false,
          message:
              'File corrupted: insufficient data for header with 1413693763 dimensions',
        );
      },
    );

    await expectLater(
      () => ensureGemma4(spec: gemma4E2b, environment: environment),
      throwsException,
    );
    expect(downloadCalls, 1);
    expect(validateCalls, 1);

    await expectLater(
      () => ensureGemma4(spec: gemma4E2b, environment: environment),
      throwsException,
    );
    expect(downloadCalls, 1);
    expect(validateCalls, 1);
  });

  test('ensureGemma4 retries incompatible refs after engine changes', () async {
    final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    var downloadCalls = 0;
    final environmentA = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-a',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['main'],
      streamDownload: (_, destPath, _) async {
        downloadCalls++;
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, _) async {
        await Directory(destDir).create(recursive: true);
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (_) async =>
          const GemmaValidationResult(success: false, message: 'bad header'),
    );

    await expectLater(
      () => ensureGemma4(spec: gemma4E2b, environment: environmentA),
      throwsException,
    );
    expect(downloadCalls, 1);

    final environmentB = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-b',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['main'],
      streamDownload: (_, destPath, _) async {
        downloadCalls++;
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, _) async {
        await Directory(destDir).create(recursive: true);
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (_) async => const GemmaValidationResult(
        success: false,
        message: 'still bad header',
      ),
    );

    await expectLater(
      () => ensureGemma4(spec: gemma4E2b, environment: environmentB),
      throwsException,
    );
    expect(downloadCalls, 2);
  });

  test(
    'ensureGemma4 does not fall through to main on non-404 download error',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      var downloadCalls = 0;
      final environment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => false,
        resolveVersions: (_) async => ['v1.13.1', 'main'],
        streamDownload: (_, destPath, _) async {
          downloadCalls++;
          await File(destPath).writeAsString('partial');
          throw Exception('Connection reset by peer');
        },
        extractZip: (_, _, _) async => fail('extractZip should not run'),
        validateExtract: (_) async => fail('validateExtract should not run'),
      );

      await expectLater(
        () => ensureGemma4(spec: gemma4E2b, environment: environment),
        throwsA(
          predicate((e) => e.toString().contains('Connection reset by peer')),
        ),
      );

      expect(downloadCalls, 1);
      final zipPath = p.join(
        tempRoot.path,
        'gemma4_weights',
        gemma4E2b.weightsFilename,
      );
      expect(await File(zipPath).exists(), isFalse);
    },
  );

  test('ensureGemma4 falls through to next candidate on 404', () async {
    final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final downloadedVersions = <String>[];
    final environment = Gemma4InstallEnvironment(
      getAppSupportDirectory: () async => tempRoot,
      getEngineCompatibilityId: () async => 'engine-a',
      preferAppleWeights: () => false,
      resolveVersions: (_) async => ['v1.13.1', 'main'],
      streamDownload: (url, destPath, _) async {
        final ref = url.split('/resolve/')[1].split('/').first;
        downloadedVersions.add(ref);
        if (ref == 'v1.13.1') {
          throw GemmaVersionMissingException(url);
        }
        await File(destPath).writeAsString('zip');
      },
      extractZip: (_, destDir, _) async {
        await Directory(destDir).create(recursive: true);
        await File(
          p.join(destDir, 'config.txt'),
        ).writeAsString('model_type=gemma4');
      },
      validateExtract: (_) async =>
          const GemmaValidationResult(success: true, message: 'ok'),
    );

    final path = await ensureGemma4(spec: gemma4E2b, environment: environment);

    expect(downloadedVersions, ['v1.13.1', 'main']);
    expect(path, p.join(tempRoot.path, 'gemma4_weights', gemma4E2b.slug));

    final marker = GemmaReadyMarker.parse(
      await File(p.join(path, '.cactus-ready')).readAsString(),
    );
    expect(marker, isNotNull);
    expect(marker!.validatedVersion, 'main');
  });

  test(
    'ensureGemma4 prefers Apple archives and falls back to generic weights on 404',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final downloadedFiles = <String>[];
      final environment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => true,
        resolveVersions: (_) async => ['main'],
        streamDownload: (url, destPath, _) async {
          final archiveName = url.split('/').last;
          downloadedFiles.add(archiveName);
          if (archiveName == 'gemma-4-e2b-it-int4-apple.zip') {
            throw GemmaVersionMissingException(url);
          }
          await File(destPath).writeAsString('zip');
        },
        extractZip: (_, destDir, _) async {
          await Directory(destDir).create(recursive: true);
          await File(
            p.join(destDir, 'config.txt'),
          ).writeAsString('model_type=gemma4');
        },
        validateExtract: (_) async =>
            const GemmaValidationResult(success: true, message: 'ok'),
      );

      final path = await ensureGemma4(
        spec: gemma4E2b,
        environment: environment,
      );

      expect(downloadedFiles, [
        'gemma-4-e2b-it-int4-apple.zip',
        'gemma-4-e2b-it-int4.zip',
      ]);
      expect(path, p.join(tempRoot.path, 'gemma4_weights', gemma4E2b.slug));

      final marker = GemmaReadyMarker.parse(
        await File(p.join(path, '.cactus-ready')).readAsString(),
      );
      expect(marker, isNotNull);
      expect(marker!.weightsFilename, gemma4E2b.weightsFilename);
    },
  );

  test(
    'ensureGemma4 remembers incompatible Apple and generic archives separately',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final downloadedFiles = <String>[];
      final environment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => true,
        resolveVersions: (_) async => ['main'],
        streamDownload: (url, destPath, _) async {
          downloadedFiles.add(url.split('/').last);
          await File(destPath).writeAsString('zip');
        },
        extractZip: (_, destDir, _) async {
          await Directory(destDir).create(recursive: true);
          await File(
            p.join(destDir, 'config.txt'),
          ).writeAsString('model_type=gemma4');
        },
        validateExtract: (_) async => const GemmaValidationResult(
          success: false,
          message: 'bad header',
        ),
      );

      await expectLater(
        () => ensureGemma4(spec: gemma4E2b, environment: environment),
        throwsException,
      );
      expect(downloadedFiles, [
        'gemma-4-e2b-it-int4-apple.zip',
        'gemma-4-e2b-it-int4.zip',
      ]);

      await expectLater(
        () => ensureGemma4(spec: gemma4E2b, environment: environment),
        throwsException,
      );
      expect(downloadedFiles, [
        'gemma-4-e2b-it-int4-apple.zip',
        'gemma-4-e2b-it-int4.zip',
      ]);
    },
  );

  test(
    'ensureGemma4Install streams extraction progress for large compressed entries',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp('gemma4-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final payload = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i % 251;
      }

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'bundle/config.txt',
            'model_type=gemma4\n'.length,
            'model_type=gemma4\n'.codeUnits,
          ),
        )
        ..addFile(ArchiveFile('bundle/weights.bin', payload.length, payload));

      final zipBytes = ZipEncoder().encode(archive);
      final sourceZip = File(p.join(tempRoot.path, 'source.zip'));
      await sourceZip.writeAsBytes(zipBytes);

      final progressMessages = <({double progress, String message})>[];
      final environment = Gemma4InstallEnvironment(
        getAppSupportDirectory: () async => tempRoot,
        getEngineCompatibilityId: () async => 'engine-a',
        preferAppleWeights: () => false,
        resolveVersions: (_) async => ['main'],
        streamDownload: (_, destPath, _) async {
          await sourceZip.copy(destPath);
        },
        validateExtract: (modelPath) async {
          final extracted = File(p.join(modelPath, 'weights.bin'));
          expect(await extracted.exists(), isTrue);
          final extractedBytes = await extracted.readAsBytes();
          expect(extractedBytes, payload);
          return const GemmaValidationResult(success: true, message: 'ok');
        },
      );

      final result = await ensureGemma4Install(
        spec: gemma4E2b,
        environment: environment,
        onProgress: (progress, message) {
          progressMessages.add((progress: progress, message: message));
        },
      );

      expect(
        progressMessages.where(
          (update) => update.message == 'Extraction complete.',
        ),
        hasLength(1),
      );
      expect(
        progressMessages.where(
          (update) => update.message.startsWith('Extracted '),
        ),
        hasLength(greaterThan(1)),
      );
      expect(result.usedCache, isFalse);
      expect(
        result.path,
        p.join(tempRoot.path, 'gemma4_weights', gemma4E2b.slug),
      );
    },
  );
}
