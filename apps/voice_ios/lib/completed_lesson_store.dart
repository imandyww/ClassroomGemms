import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One lesson the student finished (teacher pressed End). We keep enough context
/// to power the standalone Tutor tab: which subject, when, and the actual prompt
/// texts so the on-device model can ground its follow-up practice in what the
/// student just covered.
class CompletedLesson {
  final String lessonId;
  final String? subject;
  final int completedAtMs;
  final List<String> stepPrompts;

  CompletedLesson({
    required this.lessonId,
    required this.subject,
    required this.completedAtMs,
    required this.stepPrompts,
  });

  factory CompletedLesson.fromJson(Map<String, dynamic> j) => CompletedLesson(
    lessonId: j['lessonId'] as String,
    subject: j['subject'] as String?,
    completedAtMs: (j['completedAtMs'] as num).toInt(),
    stepPrompts: ((j['stepPrompts'] as List?) ?? const [])
        .map((e) => e as String)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'lessonId': lessonId,
    if (subject != null) 'subject': subject,
    'completedAtMs': completedAtMs,
    'stepPrompts': stepPrompts,
  };
}

/// JSON-backed log of completed lessons. Mirrors [PairingStore]'s pattern:
/// load on open, append on record, overwrite the file each save.
class CompletedLessonStore {
  final File _file;
  final Map<String, CompletedLesson> _byLessonId = {};

  CompletedLessonStore._(this._file);

  static Future<CompletedLessonStore> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'completed_lessons.json'));
    final store = CompletedLessonStore._(file);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    if (!await _file.exists()) return;
    try {
      final raw = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final lessons = (raw['lessons'] as List? ?? const []);
      for (final j in lessons) {
        final lesson = CompletedLesson.fromJson(j as Map<String, dynamic>);
        _byLessonId[lesson.lessonId] = lesson;
      }
    } catch (_) {
      // corrupt file - start fresh
    }
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final payload = {
      'lessons': _byLessonId.values.map((l) => l.toJson()).toList(),
    };
    await _file.writeAsString(jsonEncode(payload));
  }

  List<CompletedLesson> all() => _byLessonId.values.toList()
    ..sort((a, b) => b.completedAtMs.compareTo(a.completedAtMs));

  /// Group completed lessons by subject. Lessons with a null/empty subject are
  /// bucketed under a single `null` key.
  Map<String?, List<CompletedLesson>> bySubject() {
    final out = <String?, List<CompletedLesson>>{};
    for (final l in all()) {
      final key = (l.subject == null || l.subject!.trim().isEmpty)
          ? null
          : l.subject;
      (out[key] ??= []).add(l);
    }
    return out;
  }

  Future<void> record(CompletedLesson lesson) async {
    final existing = _byLessonId[lesson.lessonId];
    if (existing != null) {
      // Same lesson finalised twice (e.g. duplicate endLesson event). Keep the
      // richer record - the one with more captured prompts.
      if (existing.stepPrompts.length >= lesson.stepPrompts.length) return;
    }
    _byLessonId[lesson.lessonId] = lesson;
    await _save();
  }
}
