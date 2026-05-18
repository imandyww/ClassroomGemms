import 'package:shared_preferences/shared_preferences.dart';

class AgentSettingsStore {
  static const autoTrustPhoneSendersKey = 'agent_mac.auto_trust_phone_senders';

  AgentSettingsStore({Future<SharedPreferences> Function()? getPrefs})
    : _getPrefs = getPrefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _getPrefs;

  Future<bool> loadAutoTrustPhoneSenders() async {
    final prefs = await _getPrefs();
    return prefs.getBool(autoTrustPhoneSendersKey) ?? false;
  }

  Future<void> setAutoTrustPhoneSenders(bool value) async {
    final prefs = await _getPrefs();
    await prefs.setBool(autoTrustPhoneSendersKey, value);
  }
}
