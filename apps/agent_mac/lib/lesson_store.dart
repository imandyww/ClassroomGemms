import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// JSON-on-disk lesson persistence. One file per lesson under
/// `<appSupportDir>/lessons/<lessonId>.json`.
class LessonStore {
  final Directory _dir;
  LessonStore._(this._dir);

  static Future<LessonStore> open() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'lessons'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return LessonStore._(dir);
  }

  Future<void> save(Lesson lesson) async {
    final file = File(p.join(_dir.path, '${lesson.id}.json'));
    await file.writeAsString(jsonEncode(lesson.toJson()));
  }

  Future<Lesson?> load(String id) async {
    final file = File(p.join(_dir.path, '$id.json'));
    if (!await file.exists()) return null;
    try {
      return Lesson.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<Lesson>> list() async {
    if (!await _dir.exists()) return const [];
    final entries = await _dir.list().toList();
    final lessons = <Lesson>[];
    for (final e in entries) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          lessons.add(
            Lesson.fromJson(
              jsonDecode(await e.readAsString()) as Map<String, dynamic>,
            ),
          );
        } catch (_) {}
      }
    }
    lessons.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return lessons;
  }

  Future<void> delete(String id) async {
    final file = File(p.join(_dir.path, '$id.json'));
    if (await file.exists()) await file.delete();
  }
}
