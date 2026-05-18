import 'package:uuid/uuid.dart';

import 'lesson.dart';

enum Grade { correct, partial, incorrect }

Grade? gradeFromString(String? s) {
  switch (s) {
    case 'correct':
      return Grade.correct;
    case 'partial':
      return Grade.partial;
    case 'incorrect':
      return Grade.incorrect;
    default:
      return null;
  }
}

String gradeToString(Grade g) {
  switch (g) {
    case Grade.correct:
      return 'correct';
    case Grade.partial:
      return 'partial';
    case Grade.incorrect:
      return 'incorrect';
  }
}

enum GradeSource { teacher, ai }

GradeSource? gradeSourceFromString(String? s) {
  switch (s) {
    case 'teacher':
      return GradeSource.teacher;
    case 'ai':
      return GradeSource.ai;
    default:
      return null;
  }
}

String gradeSourceToString(GradeSource s) {
  switch (s) {
    case GradeSource.teacher:
      return 'teacher';
    case GradeSource.ai:
      return 'ai';
  }
}

/// One student's submitted answer to one lesson step, plus any grade applied
/// by the teacher (or AI suggestion accepted by the teacher).
class GradedResponse {
  final String studentFingerprint;
  final String studentAlias;
  final String stepId;
  final String text;
  final bool audioWasUsed;
  final int submittedAtMs;

  final Grade? grade;
  final GradeSource? gradeSource;
  final String? gradeComment;
  final int? gradedAtMs;

  const GradedResponse({
    required this.studentFingerprint,
    required this.studentAlias,
    required this.stepId,
    required this.text,
    required this.audioWasUsed,
    required this.submittedAtMs,
    this.grade,
    this.gradeSource,
    this.gradeComment,
    this.gradedAtMs,
  });

  GradedResponse copyWith({
    Grade? grade,
    GradeSource? gradeSource,
    String? gradeComment,
    int? gradedAtMs,
    String? text,
    bool? audioWasUsed,
    int? submittedAtMs,
  }) => GradedResponse(
    studentFingerprint: studentFingerprint,
    studentAlias: studentAlias,
    stepId: stepId,
    text: text ?? this.text,
    audioWasUsed: audioWasUsed ?? this.audioWasUsed,
    submittedAtMs: submittedAtMs ?? this.submittedAtMs,
    grade: grade ?? this.grade,
    gradeSource: gradeSource ?? this.gradeSource,
    gradeComment: gradeComment ?? this.gradeComment,
    gradedAtMs: gradedAtMs ?? this.gradedAtMs,
  );

  factory GradedResponse.fromJson(Map<String, dynamic> j) => GradedResponse(
    studentFingerprint: j['studentFingerprint'] as String,
    studentAlias: j['studentAlias'] as String,
    stepId: j['stepId'] as String,
    text: j['text'] as String,
    audioWasUsed: j['audioWasUsed'] as bool? ?? false,
    submittedAtMs: j['submittedAtMs'] as int,
    grade: gradeFromString(j['grade'] as String?),
    gradeSource: gradeSourceFromString(j['gradeSource'] as String?),
    gradeComment: j['gradeComment'] as String?,
    gradedAtMs: j['gradedAtMs'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'studentFingerprint': studentFingerprint,
    'studentAlias': studentAlias,
    'stepId': stepId,
    'text': text,
    'audioWasUsed': audioWasUsed,
    'submittedAtMs': submittedAtMs,
    if (grade != null) 'grade': gradeToString(grade!),
    if (gradeSource != null) 'gradeSource': gradeSourceToString(gradeSource!),
    if (gradeComment != null) 'gradeComment': gradeComment,
    if (gradedAtMs != null) 'gradedAtMs': gradedAtMs,
  };
}

/// Snapshot of one student's identity at session start. Frozen for grading
/// integrity even if the student renames themselves later.
class SessionStudent {
  final String fingerprint;
  final String alias;
  final String displayName;

  const SessionStudent({
    required this.fingerprint,
    required this.alias,
    required this.displayName,
  });

  SessionStudent copyWith({String? displayName}) => SessionStudent(
    fingerprint: fingerprint,
    alias: alias,
    displayName: displayName ?? this.displayName,
  );

  factory SessionStudent.fromJson(Map<String, dynamic> j) => SessionStudent(
    fingerprint: j['fingerprint'] as String,
    alias: j['alias'] as String,
    displayName: (j['displayName'] as String?) ?? (j['alias'] as String),
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'alias': alias,
    'displayName': displayName,
  };
}

/// One persisted run of one lesson — the unit of the gradebook. Lesson steps
/// are frozen at session start so editing the source [Lesson] later does not
/// rewrite history.
class SessionRecord {
  final String id;
  final String lessonId;
  final String lessonTitleSnapshot;
  final List<LessonStep> lessonStepsSnapshot;
  final int startedAtMs;
  final int? endedAtMs;
  final List<SessionStudent> students;
  final List<GradedResponse> responses;

  const SessionRecord({
    required this.id,
    required this.lessonId,
    required this.lessonTitleSnapshot,
    required this.lessonStepsSnapshot,
    required this.startedAtMs,
    this.endedAtMs,
    required this.students,
    required this.responses,
  });

  factory SessionRecord.start({
    required Lesson lesson,
    List<SessionStudent> students = const [],
  }) => SessionRecord(
    id: const Uuid().v4(),
    lessonId: lesson.id,
    lessonTitleSnapshot: lesson.title,
    lessonStepsSnapshot: List<LessonStep>.from(lesson.steps),
    startedAtMs: DateTime.now().millisecondsSinceEpoch,
    students: students,
    responses: const [],
  );

  SessionRecord copyWith({
    int? endedAtMs,
    List<SessionStudent>? students,
    List<GradedResponse>? responses,
  }) => SessionRecord(
    id: id,
    lessonId: lessonId,
    lessonTitleSnapshot: lessonTitleSnapshot,
    lessonStepsSnapshot: lessonStepsSnapshot,
    startedAtMs: startedAtMs,
    endedAtMs: endedAtMs ?? this.endedAtMs,
    students: students ?? this.students,
    responses: responses ?? this.responses,
  );

  factory SessionRecord.fromJson(Map<String, dynamic> j) => SessionRecord(
    id: j['id'] as String,
    lessonId: j['lessonId'] as String,
    lessonTitleSnapshot: j['lessonTitleSnapshot'] as String,
    lessonStepsSnapshot: ((j['lessonStepsSnapshot'] as List?) ?? const [])
        .map((e) => LessonStep.fromJson(e as Map<String, dynamic>))
        .toList(),
    startedAtMs: j['startedAtMs'] as int,
    endedAtMs: j['endedAtMs'] as int?,
    students: ((j['students'] as List?) ?? const [])
        .map((e) => SessionStudent.fromJson(e as Map<String, dynamic>))
        .toList(),
    responses: ((j['responses'] as List?) ?? const [])
        .map((e) => GradedResponse.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'lessonId': lessonId,
    'lessonTitleSnapshot': lessonTitleSnapshot,
    'lessonStepsSnapshot': lessonStepsSnapshot.map((s) => s.toJson()).toList(),
    'startedAtMs': startedAtMs,
    if (endedAtMs != null) 'endedAtMs': endedAtMs,
    'students': students.map((s) => s.toJson()).toList(),
    'responses': responses.map((r) => r.toJson()).toList(),
  };

  /// Convenience: fraction of (student × step) cells that have been graded.
  /// Returns 0.0 when the session has no students or no steps.
  double get gradingProgress {
    if (students.isEmpty || lessonStepsSnapshot.isEmpty) return 0.0;
    final total = students.length * lessonStepsSnapshot.length;
    final graded = responses.where((r) => r.grade != null).length;
    return graded / total;
  }

  /// Average grade as 1.0 / 0.5 / 0.0 across graded responses only. Returns
  /// null when nothing has been graded.
  double? get averageScore {
    final graded = responses.where((r) => r.grade != null).toList();
    if (graded.isEmpty) return null;
    final sum = graded.fold<double>(0, (acc, r) {
      switch (r.grade!) {
        case Grade.correct:
          return acc + 1.0;
        case Grade.partial:
          return acc + 0.5;
        case Grade.incorrect:
          return acc + 0.0;
      }
    });
    return sum / graded.length;
  }
}
