import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Stable per-install device identity. The fingerprint is a random uuid (not a
/// TLS cert hash — we're not doing TLS in MVP). It persists across launches so
/// a paired peer recognizes us.
class DeviceIdentity {
  static const _kAlias = 'lan.alias';
  static const _kFingerprint = 'lan.fingerprint';

  final String alias;
  final String fingerprint;

  const DeviceIdentity({required this.alias, required this.fingerprint});

  static Future<DeviceIdentity> loadOrCreate({String? defaultAlias}) async {
    final prefs = await SharedPreferences.getInstance();
    var alias = prefs.getString(_kAlias);
    var fingerprint = prefs.getString(_kFingerprint);
    if (alias == null) {
      alias = defaultAlias ?? _defaultAlias();
      await prefs.setString(_kAlias, alias);
    }
    if (fingerprint == null) {
      fingerprint = const Uuid().v4();
      await prefs.setString(_kFingerprint, fingerprint);
    }
    return DeviceIdentity(alias: alias, fingerprint: fingerprint);
  }

  static String _defaultAlias() {
    final host = Platform.localHostname;
    return host.isEmpty ? 'Agent-Device' : host;
  }

  static String deviceType() {
    if (Platform.isIOS || Platform.isAndroid) return 'mobile';
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return 'desktop';
    return 'headless';
  }
}
