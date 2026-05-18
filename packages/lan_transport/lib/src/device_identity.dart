import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Stable per-install device identity. The fingerprint is a random uuid (not a
/// TLS cert hash — we're not doing TLS in MVP). It persists across launches so
/// a paired peer recognizes us.
///
/// [alias] is the human-readable name shown to other peers. Callers may rename
/// the device at runtime via [setAlias]; the new value is broadcast on the
/// next multicast announce and included in subsequent HTTP requests.
class DeviceIdentity {
  static const _kAlias = 'lan.alias';
  static const _kFingerprint = 'lan.fingerprint';
  static const _kAliasUserChosen = 'lan.aliasUserChosen';

  String alias;
  final String fingerprint;
  bool aliasIsUserChosen;

  DeviceIdentity({
    required this.alias,
    required this.fingerprint,
    this.aliasIsUserChosen = false,
  });

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
    final userChosen = prefs.getBool(_kAliasUserChosen) ?? false;
    return DeviceIdentity(
      alias: alias,
      fingerprint: fingerprint,
      aliasIsUserChosen: userChosen,
    );
  }

  /// Update the alias used in future multicast announcements and HTTP
  /// requests. Persists immediately. Passing [userChosen] true marks the
  /// alias as having been explicitly set by the user (used by client apps to
  /// know whether to keep nagging for a name).
  Future<void> setAlias(String newAlias, {bool userChosen = true}) async {
    final trimmed = newAlias.trim();
    if (trimmed.isEmpty) return;
    alias = trimmed;
    aliasIsUserChosen = userChosen;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAlias, trimmed);
    await prefs.setBool(_kAliasUserChosen, userChosen);
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
