import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'peer.dart';

/// JSON-backed fingerprint allowlist: if a peer's fingerprint is in here,
/// we auto-accept its requests. First-time peers require explicit approval.
class PairingStore {
  final File _file;
  final Map<String, LanPeer> _byFingerprint = {};

  PairingStore._(this._file);

  static Future<PairingStore> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'lan_pairings.json'));
    final store = PairingStore._(file);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    if (!await _file.exists()) return;
    try {
      final raw = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final peers = (raw['peers'] as List? ?? const []);
      for (final j in peers) {
        final peer = LanPeer.fromJson(j as Map<String, dynamic>);
        _byFingerprint[peer.fingerprint] = peer;
      }
    } catch (_) {
      // corrupt file — start fresh
    }
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final payload = {
      'peers': _byFingerprint.values.map((p) => p.toJson()).toList(),
    };
    await _file.writeAsString(jsonEncode(payload));
  }

  bool isTrusted(String fingerprint) => _byFingerprint.containsKey(fingerprint);

  LanPeer? get(String fingerprint) => _byFingerprint[fingerprint];

  List<LanPeer> all() => _byFingerprint.values.toList();

  Future<void> trust(LanPeer peer) async {
    _byFingerprint[peer.fingerprint] = peer;
    await _save();
  }

  Future<void> forget(String fingerprint) async {
    _byFingerprint.remove(fingerprint);
    await _save();
  }
}
