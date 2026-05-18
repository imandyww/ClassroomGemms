import 'package:cactus/cactus.dart';
import 'package:cactus/src/services/api/telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initializeModel surfaces native init errors', () async {
    Telemetry('project', 'device', null);
    final lm = CactusLM(
      initContext: (modelPath, contextSize) async =>
          (null, 'native init blew up'),
    );

    await expectLater(
      () => lm.initializeModel(
        params: CactusInitParams(
          model: 'gemma-4-e2b-it',
          modelPath: '/tmp/gemma-4-e2b-it',
          contextSize: 256,
        ),
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('native init blew up'),
        ),
      ),
    );
  });
}
