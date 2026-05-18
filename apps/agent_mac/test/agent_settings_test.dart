import 'package:agent_mac/agent_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentSettingsStore', () {
    test('defaults auto-trust to disabled', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AgentSettingsStore();

      expect(await store.loadAutoTrustPhoneSenders(), isFalse);
    });

    test('persists auto-trust toggle', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AgentSettingsStore();

      await store.setAutoTrustPhoneSenders(true);

      expect(await store.loadAutoTrustPhoneSenders(), isTrue);
    });
  });
}
