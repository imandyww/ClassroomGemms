import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCactusLM extends CactusLM {
  _FakeCactusLM({this.onInitialize, this.onCompletion})
    : super(enableToolFiltering: false);

  final Future<void> Function(CactusInitParams params)? onInitialize;
  final Future<CactusCompletionResult> Function({
    required List<ChatMessage> messages,
    required CactusCompletionParams? params,
  })?
  onCompletion;

  final List<CactusInitParams> initializeCalls = [];
  final List<({List<ChatMessage> messages, CactusCompletionParams? params})>
  completionCalls = [];
  int resetCalls = 0;
  bool _loaded = false;

  @override
  Future<void> initializeModel({CactusInitParams? params}) async {
    final resolved = params ?? CactusInitParams();
    initializeCalls.add(resolved);
    if (onInitialize != null) {
      await onInitialize!(resolved);
    }
    _loaded = true;
  }

  @override
  bool isLoaded() => _loaded;

  @override
  void unload() {
    _loaded = false;
  }

  @override
  void reset() {
    resetCalls += 1;
  }

  @override
  Future<CactusCompletionResult> generateCompletion({
    required List<ChatMessage> messages,
    CactusCompletionParams? params,
  }) async {
    completionCalls.add((messages: messages, params: params));
    if (onCompletion != null) {
      return onCompletion!(messages: messages, params: params);
    }
    return CactusCompletionResult(
      success: true,
      response: 'ok',
      timeToFirstTokenMs: 0,
      totalTimeMs: 0,
      tokensPerSecond: 0,
      prefillTokens: 0,
      decodeTokens: 0,
      totalTokens: 0,
    );
  }
}

void main() {
  group('SttBootstrap', () {
    test(
      'desktop STT falls back from e4b to e2b and sends audio through completion',
      () async {
        final requestedSpecs = <String>[];
        final lm = _FakeCactusLM(
          onInitialize: (params) async {
            if (params.model == gemma4E4b.slug) {
              throw Exception('e4b failed');
            }
          },
          onCompletion: ({required messages, required params}) async {
            return CactusCompletionResult(
              success: true,
              response: 'hello 123',
              timeToFirstTokenMs: 0,
              totalTimeMs: 0,
              tokensPerSecond: 0,
              prefillTokens: 0,
              decodeTokens: 0,
              totalTokens: 0,
            );
          },
        );

        final boot = SttBootstrap(
          lm: lm,
          tier: DeviceTier.desktop,
          resolveRuntimeProfile: (_) async => LmRuntimeProfile.desktop,
          ensureGemmaInstall:
              ({required spec, forceRefresh = false, onProgress}) async {
                requestedSpecs.add(spec.slug);
                return Gemma4InstallResult(
                  path: '/tmp/${spec.slug}',
                  usedCache: false,
                );
              },
        );

        final result = await boot.transcribeFile('/tmp/sample.wav');

        expect(result, 'hello 123');
        expect(requestedSpecs, [gemma4E4b.slug, gemma4E2b.slug]);
        expect(lm.initializeCalls.map((call) => call.model).toList(), [
          gemma4E4b.slug,
          gemma4E4b.slug,
          gemma4E4b.slug,
          gemma4E2b.slug,
        ]);
        expect(lm.initializeCalls.last.modelPath, '/tmp/${gemma4E2b.slug}');
        expect(lm.completionCalls.single.messages.single.audio, [
          '/tmp/sample.wav',
        ]);
        expect(
          lm.completionCalls.single.messages.single.content,
          SttBootstrap.gemmaTranscriptionPrompt,
        );
        expect(lm.completionCalls.single.params?.stopSequences, isEmpty);
        expect(lm.completionCalls.single.params?.temperature, 0);
        expect(lm.resetCalls, 1);
      },
    );

    test('demo simulator STT loads the preloaded e2b path', () async {
      final tempDir = await Directory.systemTemp.createTemp('gemma-demo-stt-');
      final demoRoot = Directory(
        '${tempDir.path}/gemma4_demo/${gemma4E2b.slug}',
      )..createSync(recursive: true);
      File(
        '${demoRoot.path}/config.txt',
      ).writeAsStringSync('model_type=gemma4');
      final lm = _FakeCactusLM();

      final boot = SttBootstrap(
        lm: lm,
        tier: DeviceTier.phone,
        demoSettings: const VoiceAgentDemoSettings(
          enabled: true,
          hostRootPath: '/demo-root',
        ),
        getAppSupportDirectory: () async => tempDir,
        resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
        ensureGemmaInstall:
            ({required spec, forceRefresh = false, onProgress}) async {
              fail('demo mode should not invoke the installer');
            },
      );

      await boot.ensureReady();

      expect(lm.initializeCalls, isNotEmpty);
      expect(lm.initializeCalls.first.model, gemma4E2b.slug);
      expect(lm.initializeCalls.first.modelPath, demoRoot.path);
    });

    test('missing demo preload surfaces the preload hint', () async {
      final tempDir = await Directory.systemTemp.createTemp('gemma-demo-stt-');
      final lm = _FakeCactusLM();

      final boot = SttBootstrap(
        lm: lm,
        tier: DeviceTier.phone,
        demoSettings: const VoiceAgentDemoSettings(
          enabled: true,
          hostRootPath: '/demo-root',
        ),
        getAppSupportDirectory: () async => tempDir,
        resolveRuntimeProfile: (_) async => LmRuntimeProfile.iosSimulator,
      );

      await expectLater(
        boot.ensureReady(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('./preload_gemma_demo.command'),
              contains('Gemma STT model'),
              contains(gemma4E2b.slug),
            ),
          ),
        ),
      );
    });
  });
}
