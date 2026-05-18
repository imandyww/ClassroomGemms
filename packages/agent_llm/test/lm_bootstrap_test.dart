import 'dart:async';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCactusLM extends CactusLM {
  _FakeCactusLM({this.onInitialize}) : super(enableToolFiltering: false);

  final Future<void> Function(CactusInitParams params)? onInitialize;

  final List<CactusInitParams> initializeCalls = [];
  final List<String> downloadCalls = [];

  @override
  Future<void> initializeModel({CactusInitParams? params}) async {
    final resolved = params ?? CactusInitParams();
    initializeCalls.add(resolved);
    if (onInitialize != null) {
      await onInitialize!(resolved);
    }
  }

  @override
  Future<void> downloadModel({
    String model = 'qwen3-0.6',
    CactusProgressCallback? downloadProcessCallback,
  }) async {
    downloadCalls.add(model);
  }
}

void main() {
  group('LmBootstrap', () {
    test('uses the simulator context ladder', () async {
      final gemmaContexts = <int>[];
      final lm = _FakeCactusLM(
        onInitialize: (params) async {
          if (params.model != gemma4E2b.slug) {
            return;
          }
          gemmaContexts.add(params.contextSize!);
          if (params.contextSize == 512) {
            throw Exception('simulator 512 failed');
          }
        },
      );

      final boot = LmBootstrap(
        tier: DeviceTier.phone,
        lm: lm,
        resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
        ensureGemmaInstall:
            ({required spec, forceRefresh = false, onProgress}) async {
              expect(spec.slug, gemma4E2b.slug);
              expect(forceRefresh, isFalse);
              return const Gemma4InstallResult(
                path: '/tmp/gemma-sim',
                usedCache: false,
              );
            },
        validateModelPath: (modelPath, {required contextSize}) async {
          fail('fresh simulator weights should not trigger validation');
        },
      );

      final result = await boot.ensureReady();

      expect(result.slug, gemma4E2b.slug);
      expect(result.isFallback, isFalse);
      expect(gemmaContexts, [512, 256]);
      expect(lm.downloadCalls, isEmpty);
    });

    test('uses the physical iPhone context ladder', () async {
      final gemmaContexts = <int>[];
      final lm = _FakeCactusLM(
        onInitialize: (params) async {
          if (params.model != gemma4E2b.slug) {
            return;
          }
          gemmaContexts.add(params.contextSize!);
          if (params.contextSize != 256) {
            throw Exception('needs smaller context');
          }
        },
      );

      final boot = LmBootstrap(
        tier: DeviceTier.phone,
        lm: lm,
        resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosDevice,
        ensureGemmaInstall:
            ({required spec, forceRefresh = false, onProgress}) async =>
                const Gemma4InstallResult(
                  path: '/tmp/gemma-phone',
                  usedCache: false,
                ),
        validateModelPath: (modelPath, {required contextSize}) async {
          fail('fresh phone weights should not trigger validation');
        },
      );

      final result = await boot.ensureReady();

      expect(result.slug, gemma4E2b.slug);
      expect(result.isFallback, isFalse);
      expect(gemmaContexts, [1024, 512, 256]);
      expect(lm.downloadCalls, isEmpty);
    });

    test('phone tier never attempts gemma-4-e4b-it or qwen fallback', () async {
      final requestedSpecs = <String>[];
      final lm = _FakeCactusLM(
        onInitialize: (params) async {
          if (params.model == gemma4E2b.slug) {
            throw Exception('gemma init failed');
          }
        },
      );

      final boot = LmBootstrap(
        tier: DeviceTier.phone,
        lm: lm,
        resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
        ensureGemmaInstall:
            ({required spec, forceRefresh = false, onProgress}) async {
              requestedSpecs.add(spec.slug);
              return const Gemma4InstallResult(
                path: '/tmp/gemma-phone',
                usedCache: false,
              );
            },
        validateModelPath: (modelPath, {required contextSize}) async {
          fail('fresh failures should fall back without validation');
        },
      );

      await expectLater(
        boot.ensureReady(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('gemma init failed'),
              contains('${gemma4E2b.slug} is the only model supported on iOS'),
            ),
          ),
        ),
      );

      expect(requestedSpecs, [gemma4E2b.slug]);
      expect(lm.downloadCalls, isEmpty);
    });

    test(
      'coalesces concurrent ensureReady calls into one Gemma install',
      () async {
        final requestedSpecs = <String>[];
        final installCompleter = Completer<Gemma4InstallResult>();
        final gemmaContexts = <int>[];
        final statusMessages = <String>[];
        final lm = _FakeCactusLM(
          onInitialize: (params) async {
            if (params.model == gemma4E2b.slug) {
              gemmaContexts.add(params.contextSize!);
            }
          },
        );

        final boot = LmBootstrap(
          tier: DeviceTier.phone,
          lm: lm,
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) {
                requestedSpecs.add(spec.slug);
                return installCompleter.future;
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            fail('fresh simulator weights should not trigger validation');
          },
        );

        final first = boot.ensureReady();
        final second = boot.ensureReady(onStatus: statusMessages.add);

        installCompleter.complete(
          const Gemma4InstallResult(path: '/tmp/gemma-sim', usedCache: false),
        );

        final firstResult = await first;
        final secondResult = await second;

        expect(requestedSpecs, [gemma4E2b.slug]);
        expect(firstResult.slug, gemma4E2b.slug);
        expect(secondResult.slug, gemma4E2b.slug);
        expect(gemmaContexts, [512]);
        expect(
          statusMessages,
          contains(
            'Model load already in progress. Waiting for the active attempt...',
          ),
        );
      },
    );

    test(
      'desktop still falls back to qwen after both Gemma specs fail',
      () async {
        final requestedSpecs = <String>[];
        final lm = _FakeCactusLM(
          onInitialize: (params) async {
            if (params.model == gemma4E4b.slug ||
                params.model == gemma4E2b.slug) {
              throw Exception('gemma init failed');
            }
          },
        );

        final boot = LmBootstrap(
          tier: DeviceTier.desktop,
          lm: lm,
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.desktop,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add(spec.slug);
                return Gemma4InstallResult(
                  path: '/tmp/${spec.slug}',
                  usedCache: false,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            fail('fresh desktop failures should fall through to fallback');
          },
        );

        final result = await boot.ensureReady();

        expect(requestedSpecs, [gemma4E4b.slug, gemma4E2b.slug]);
        expect(lm.downloadCalls, [fallbackSlug]);
        expect(result.slug, fallbackSlug);
        expect(result.isFallback, isTrue);
      },
    );

    test(
      'demo desktop loads preloaded e2b from host root without installer or fallback',
      () async {
        final requestedSpecs = <String>[];
        final validationCalls = <({String modelPath, int contextSize})>[];
        final lm = _FakeCactusLM();

        final boot = LmBootstrap(
          tier: DeviceTier.desktop,
          lm: lm,
          demoSettings: const VoiceAgentDemoSettings(
            enabled: true,
            hostRootPath: '/demo-root',
          ),
          getAppSupportDirectory: () async => Directory('/unused'),
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.desktop,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add(spec.slug);
                return const Gemma4InstallResult(
                  path: '/tmp/should-not-run',
                  usedCache: false,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            validationCalls.add((
              modelPath: modelPath,
              contextSize: contextSize,
            ));
            return const GemmaValidationResult(success: true, message: 'ok');
          },
        );

        final result = await boot.ensureReady();

        expect(result.slug, gemma4E2b.slug);
        expect(result.modelPath, '/demo-root/${gemma4E2b.slug}');
        expect(result.sourceLabel, 'Preloaded Gemma-4-E2B');
        expect(result.isFallback, isFalse);
        expect(requestedSpecs, isEmpty);
        expect(lm.downloadCalls, isEmpty);
        expect(validationCalls, [
          (modelPath: '/demo-root/${gemma4E2b.slug}', contextSize: 1024),
        ]);
        expect(
          lm.initializeCalls.map((call) => call.model).toList(),
          everyElement(gemma4E2b.slug),
        );
        expect(
          lm.initializeCalls.first.modelPath,
          '/demo-root/${gemma4E2b.slug}',
        );
      },
    );

    test(
      'demo simulator loads preloaded e2b from sandbox path without installer or fallback',
      () async {
        final requestedSpecs = <String>[];
        final validationCalls = <({String modelPath, int contextSize})>[];
        final lm = _FakeCactusLM();

        final boot = LmBootstrap(
          tier: DeviceTier.phone,
          lm: lm,
          demoSettings: const VoiceAgentDemoSettings(
            enabled: true,
            hostRootPath: '/demo-root',
          ),
          getAppSupportDirectory: () async =>
              Directory('/simulator/AppSupport'),
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add(spec.slug);
                return const Gemma4InstallResult(
                  path: '/tmp/should-not-run',
                  usedCache: false,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            validationCalls.add((
              modelPath: modelPath,
              contextSize: contextSize,
            ));
            return const GemmaValidationResult(success: true, message: 'ok');
          },
        );

        final result = await boot.ensureReady();

        expect(result.slug, gemma4E2b.slug);
        expect(
          result.modelPath,
          '/simulator/AppSupport/gemma4_demo/${gemma4E2b.slug}',
        );
        expect(result.sourceLabel, 'Preloaded Gemma-4-E2B');
        expect(requestedSpecs, isEmpty);
        expect(lm.downloadCalls, isEmpty);
        expect(validationCalls, [
          (
            modelPath: '/simulator/AppSupport/gemma4_demo/${gemma4E2b.slug}',
            contextSize: 256,
          ),
        ]);
        expect(
          lm.initializeCalls.map((call) => call.model).toList(),
          everyElement(gemma4E2b.slug),
        );
        expect(
          lm.initializeCalls.first.modelPath,
          '/simulator/AppSupport/gemma4_demo/${gemma4E2b.slug}',
        );
      },
    );

    test(
      'demo mode fails loudly without fallback when preloaded model is invalid',
      () async {
        final requestedSpecs = <String>[];
        final lm = _FakeCactusLM();

        final boot = LmBootstrap(
          tier: DeviceTier.desktop,
          lm: lm,
          demoSettings: const VoiceAgentDemoSettings(
            enabled: true,
            hostRootPath: '/demo-root',
          ),
          getAppSupportDirectory: () async => Directory('/unused'),
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.desktop,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add(spec.slug);
                return const Gemma4InstallResult(
                  path: '/tmp/should-not-run',
                  usedCache: false,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            return const GemmaValidationResult(
              success: false,
              message: 'missing config.txt',
            );
          },
        );

        await expectLater(
          boot.ensureReady(),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('/demo-root/${gemma4E2b.slug}'),
                contains('./preload_gemma_demo.command'),
                contains('missing config.txt'),
              ),
            ),
          ),
        );
        expect(requestedSpecs, isEmpty);
        expect(lm.initializeCalls, isEmpty);
        expect(lm.downloadCalls, isEmpty);
      },
    );

    test(
      'cached init failure plus failed validation triggers one forced refresh pass and surfaces failure on iOS',
      () async {
        final requestedSpecs = <({String slug, bool forceRefresh})>[];
        final validationCalls = <({String modelPath, int contextSize})>[];
        final gemmaContexts = <int>[];
        final lm = _FakeCactusLM(
          onInitialize: (params) async {
            if (params.model == gemma4E2b.slug) {
              gemmaContexts.add(params.contextSize!);
              throw Exception('gemma init failed');
            }
          },
        );

        final boot = LmBootstrap(
          tier: DeviceTier.phone,
          lm: lm,
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add((
                  slug: spec.slug,
                  forceRefresh: forceRefresh,
                ));
                return Gemma4InstallResult(
                  path: forceRefresh
                      ? '/tmp/gemma-refresh'
                      : '/tmp/gemma-cache',
                  usedCache: !forceRefresh,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            validationCalls.add((
              modelPath: modelPath,
              contextSize: contextSize,
            ));
            return const GemmaValidationResult(
              success: false,
              message: 'bad header',
            );
          },
        );

        await expectLater(
          boot.ensureReady(),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('forced refresh'),
                contains(
                  '${gemma4E2b.slug} is the only model supported on iOS',
                ),
              ),
            ),
          ),
        );
        expect(requestedSpecs, [
          (slug: gemma4E2b.slug, forceRefresh: false),
          (slug: gemma4E2b.slug, forceRefresh: true),
        ]);
        expect(validationCalls, [
          (modelPath: '/tmp/gemma-cache', contextSize: 256),
        ]);
        expect(gemmaContexts, [512, 256, 512, 256]);
        expect(lm.downloadCalls, isEmpty);
      },
    );

    test(
      'cached init failure plus successful validation skips refresh and surfaces failure on iOS',
      () async {
        final requestedSpecs = <({String slug, bool forceRefresh})>[];
        final validationCalls = <({String modelPath, int contextSize})>[];
        final gemmaContexts = <int>[];
        final lm = _FakeCactusLM(
          onInitialize: (params) async {
            if (params.model == gemma4E2b.slug) {
              gemmaContexts.add(params.contextSize!);
              throw Exception('still too big');
            }
          },
        );

        final boot = LmBootstrap(
          tier: DeviceTier.phone,
          lm: lm,
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add((
                  slug: spec.slug,
                  forceRefresh: forceRefresh,
                ));
                return const Gemma4InstallResult(
                  path: '/tmp/gemma-cache',
                  usedCache: true,
                );
              },
          validateModelPath: (modelPath, {required contextSize}) async {
            validationCalls.add((
              modelPath: modelPath,
              contextSize: contextSize,
            ));
            return const GemmaValidationResult(
              success: true,
              message: 'Context initialized successfully',
            );
          },
        );

        await expectLater(
          boot.ensureReady(),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('cached validation success'),
                contains(
                  '${gemma4E2b.slug} is the only model supported on iOS',
                ),
              ),
            ),
          ),
        );

        expect(requestedSpecs, [(slug: gemma4E2b.slug, forceRefresh: false)]);
        expect(validationCalls, [
          (modelPath: '/tmp/gemma-cache', contextSize: 256),
        ]);
        expect(gemmaContexts, [512, 256]);
        expect(lm.downloadCalls, isEmpty);
      },
    );
  });
}
