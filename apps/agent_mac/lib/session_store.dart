import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// JSON-on-disk persistence for completed (or in-progress) classroom sessions.
/// One file per session under `<appSupportDir>/sessions/<sessionId>.json`.
///
/// Same shape as [LessonStore] — see `lesson_store.dart`.
class SessionStore {
  final Directory _dir;
  SessionStore._(this._dir);

  static Future<SessionStore> open() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'sessions'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return SessionStore._(dir);
  }

  Future<void> save(SessionRecord session) async {
    final file = File(p.join(_dir.path, '${session.id}.json'));
    await file.writeAsString(jsonEncode(session.toJson()));
  }

  Future<SessionRecord?> load(String id) async {
    final file = File(p.join(_dir.path, '$id.json'));
    if (!await file.exists()) return null;
    try {
      return SessionRecord.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<SessionRecord>> list() async {
    if (!await _dir.exists()) return const [];
    final entries = await _dir.list().toList();
    final sessions = <SessionRecord>[];
    for (final e in entries) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          sessions.add(
            SessionRecord.fromJson(
              jsonDecode(await e.readAsString()) as Map<String, dynamic>,
            ),
          );
        } catch (_) {}
      }
    }
    sessions.sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    return sessions;
  }

  Future<void> delete(String id) async {
    final file = File(p.join(_dir.path, '$id.json'));
    if (await file.exists()) await file.delete();
  }
}
