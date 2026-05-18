import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

/// Builds and writes a CSV gradebook for one session. Each row is one student;
/// columns are: name, alias, fingerprint, started_at, then for each lesson
/// step `step{N}_grade`, `step{N}_comment`, `step{N}_text`.
///
/// Writes to `~/Downloads/classroom-<sessionId>.csv` and returns the path. We
/// keep this dependency-free (no file_selector) so the demo works out of the
/// box; the teacher can move/rename the file from Finder.
class CsvExportResult {
  final String path;
  final int rowCount;
  const CsvExportResult({required this.path, required this.rowCount});
}

Future<CsvExportResult> exportSessionCsv(SessionRecord session) async {
  final lines = <String>[];
  final stepIds = session.lessonStepsSnapshot.map((s) => s.id).toList();

  final header = <String>[
    'display_name',
    'alias',
    'fingerprint',
    'session_started',
    for (var i = 0; i < stepIds.length; i++) ...[
      'step${i + 1}_grade',
      'step${i + 1}_comment',
      'step${i + 1}_text',
    ],
  ];
  lines.add(header.map(_quote).join(','));

  final startedIso = DateTime.fromMillisecondsSinceEpoch(
    session.startedAtMs,
  ).toIso8601String();

  for (final student in session.students) {
    final row = <String>[
      student.displayName,
      student.alias,
      student.fingerprint,
      startedIso,
    ];
    for (final stepId in stepIds) {
      final resp = session.responses.firstWhere(
        (r) =>
            r.studentFingerprint == student.fingerprint && r.stepId == stepId,
        orElse: () => GradedResponse(
          studentFingerprint: student.fingerprint,
          studentAlias: student.alias,
          stepId: stepId,
          text: '',
          audioWasUsed: false,
          submittedAtMs: 0,
        ),
      );
      row.add(resp.grade == null ? '' : gradeToString(resp.grade!));
      row.add(resp.gradeComment ?? '');
      row.add(resp.text);
    }
    lines.add(row.map(_quote).join(','));
  }

  final downloads = _downloadsDir();
  if (!await downloads.exists()) {
    await downloads.create(recursive: true);
  }
  final filename =
      'classroom-${_safeTitle(session.lessonTitleSnapshot)}-${session.id.substring(0, 8)}.csv';
  final file = File(p.join(downloads.path, filename));
  await file.writeAsString(lines.join('\n'));
  return CsvExportResult(path: file.path, rowCount: session.students.length);
}

Directory _downloadsDir() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return Directory.systemTemp;
  }
  return Directory(p.join(home, 'Downloads'));
}

String _safeTitle(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .toLowerCase();
  if (cleaned.isEmpty) return 'session';
  return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
}

String _quote(String value) {
  final needsQuotes =
      value.contains(',') || value.contains('"') || value.contains('\n');
  final escaped = value.replaceAll('"', '""');
  return needsQuotes ? '"$escaped"' : escaped;
}
