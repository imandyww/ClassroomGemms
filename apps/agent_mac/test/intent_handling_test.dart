import 'package:agent_llm/agent_llm.dart';
import 'package:agent_mac/intent_handling.dart';
import 'package:agent_mac/pairing_policy.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transport/lan_transport.dart';

void main() {
  group('matchIntentFastPath', () {
    test('matches spotlight phrases and maps to cmd-space', () {
      const inputs = [
        'Open Spotlight.',
        'show spotlight',
        'Bring up the Spotlight!',
      ];

      for (final input in inputs) {
        final fastPath = matchIntentFastPath(input);
        expect(fastPath, isNotNull, reason: input);
        expect(fastPath!.name, 'spotlight');
        expect(fastPath.toolName, 'pressKeys');
        expect(fastPath.toolArguments['keys'], spotlightFastPathKeys);
      }
    });

    test('ignores unrelated intents', () {
      expect(matchIntentFastPath('Open Calendar'), isNull);
    });
  });

  test('zero-trace runs log a warning while preserving success semantics', () {
    final logs = <String>[];
    final request = IntentRequest.create(
      text: 'Open Spotlight.',
      sourceDevice: 'test',
    );
    final run = AgentRun(
      success: true,
      finalText: 'Open Spotlight.',
      trace: [],
    );

    final response = buildIntentResponseFromRun(
      request: request,
      run: run,
      modelSlug: 'qwen3-1.7',
      isFallback: true,
      onLog: logs.add,
    );

    expect(response.success, isTrue);
    expect(response.text, 'Open Spotlight.');
    expect(response.trace, isEmpty);
    expect(logs, hasLength(1));
    expect(logs.single, contains('model=qwen3-1.7'));
    expect(logs.single, contains('fallback=yes'));
    expect(logs.single, contains('No macOS action executed.'));
  });

  group('shouldAutoTrustIncomingPeer', () {
    test('auto-trusts mobile send-only peers from voice_ios', () {
      final peer = LanPeer(
        alias: 'iPhone-Agent',
        fingerprint: 'abc123',
        ip: '192.168.1.10',
        port: 53317,
        deviceType: 'mobile',
        acceptsIntents: false,
        lastSeen: DateTime.now(),
      );

      expect(shouldAutoTrustIncomingPeer(peer), isTrue);
    });

    test('does not auto-trust desktop peers that accept intents', () {
      final peer = LanPeer(
        alias: 'Agent-Mac',
        fingerprint: 'def456',
        ip: '192.168.1.20',
        port: 53317,
        deviceType: 'desktop',
        acceptsIntents: true,
        lastSeen: DateTime.now(),
      );

      expect(shouldAutoTrustIncomingPeer(peer), isFalse);
    });
  });
}
