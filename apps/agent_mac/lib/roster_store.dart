import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists teacher-chosen display names for student fingerprints. Single
/// flat JSON file at `<appSupportDir>/students/roster.json`.
///
/// Renaming "Student-iPhone-7" to "Maria" sticks across sessions and app
/// restarts. New fingerprints fall back to the alias the student app
/// advertised.
class RosterStore {
  final File _file;
  final Map<String, String> _byFingerprint;

  RosterStore._(this._file, this._byFingerprint);

  static Future<RosterStore> open() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'students'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'roster.json'));
    final map = <String, String>{};
    if (await file.exists()) {
      try {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          if (v is String) map[k] = v;
        });
      } catch (_) {
        // Corrupt roster file is non-fatal; we just start empty.
      }
    }
    return RosterStore._(file, map);
  }

  /// Display name for [fingerprint], or null if the teacher hasn't renamed
  /// this student.
  String? displayName(String fingerprint) => _byFingerprint[fingerprint];

  /// Display name for [fingerprint] falling back to [alias] if no override
  /// is stored.
  String resolveName(String fingerprint, String alias) =>
      _byFingerprint[fingerprint] ?? alias;

  Map<String, String> get all => Map.unmodifiable(_byFingerprint);

  Future<void> setDisplayName(String fingerprint, String displayName) async {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      _byFingerprint.remove(fingerprint);
    } else {
      _byFingerprint[fingerprint] = trimmed;
    }
    await _file.writeAsString(jsonEncode(_byFingerprint));
  }
}
