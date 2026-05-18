import 'package:uuid/uuid.dart';

const Object _unset = Object();

enum ExpectedFormat { free, short, multipleChoice }

ExpectedFormat _formatFromString(String? s) {
  switch (s) {
    case 'short':
      return ExpectedFormat.short;
    case 'multipleChoice':
      return ExpectedFormat.multipleChoice;
    case 'free':
    default:
      return ExpectedFormat.free;
  }
}

String _formatToString(ExpectedFormat f) {
  switch (f) {
    case ExpectedFormat.short:
      return 'short';
    case ExpectedFormat.multipleChoice:
      return 'multipleChoice';
    case ExpectedFormat.free:
      return 'free';
  }
}

class LessonStep {
  final String id;
  final int index;
  final String prompt;
  final String? teacherNotes;
  final ExpectedFormat expectedFormat;
  final List<String> options;

  /// Optional answer key the teacher provides for AI-assisted grading of
  /// `free` or `short` answers. Ignored for `multipleChoice` (use
  /// [correctOptionIndex] there). Backward-compatible: existing on-disk lessons
  /// without this field load with `null` and the grading UI prompts the
  /// teacher to add an expected answer before AI grading is offered.
  final String? expectedAnswer;

  /// Index into [options] of the correct choice for `multipleChoice` steps.
  /// Enables a no-LLM grading fast path. Optional; null means "no answer key".
  final int? correctOptionIndex;

  LessonStep({
    required this.id,
    required this.index,
    required this.prompt,
    this.teacherNotes,
    this.expectedFormat = ExpectedFormat.free,
    this.options = const [],
    this.expectedAnswer,
    this.correctOptionIndex,
  });

  factory LessonStep.create({
    required int index,
    required String prompt,
    String? teacherNotes,
    ExpectedFormat expectedFormat = ExpectedFormat.free,
    List<String> options = const [],
    String? expectedAnswer,
    int? correctOptionIndex,
  }) => LessonStep(
    id: const Uuid().v4(),
    index: index,
    prompt: prompt,
    teacherNotes: teacherNotes,
    expectedFormat: expectedFormat,
    options: options,
    expectedAnswer: expectedAnswer,
    correctOptionIndex: correctOptionIndex,
  );

  factory LessonStep.fromJson(Map<String, dynamic> j) => LessonStep(
    id: j['id'] as String,
    index: j['index'] as int,
    prompt: j['prompt'] as String,
    teacherNotes: j['teacherNotes'] as String?,
    expectedFormat: _formatFromString(j['expectedFormat'] as String?),
    options: ((j['options'] as List?) ?? const [])
        .map((e) => e as String)
        .toList(),
    expectedAnswer: j['expectedAnswer'] as String?,
    correctOptionIndex: j['correctOptionIndex'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'prompt': prompt,
    if (teacherNotes != null) 'teacherNotes': teacherNotes,
    'expectedFormat': _formatToString(expectedFormat),
    'options': options,
    if (expectedAnswer != null) 'expectedAnswer': expectedAnswer,
    if (correctOptionIndex != null) 'correctOptionIndex': correctOptionIndex,
  };

  LessonStep copyWith({
    int? index,
    String? prompt,
    Object? teacherNotes = _unset,
    ExpectedFormat? expectedFormat,
    List<String>? options,
    Object? expectedAnswer = _unset,
    Object? correctOptionIndex = _unset,
  }) => LessonStep(
    id: id,
    index: index ?? this.index,
    prompt: prompt ?? this.prompt,
    teacherNotes: identical(teacherNotes, _unset)
        ? this.teacherNotes
        : teacherNotes as String?,
    expectedFormat: expectedFormat ?? this.expectedFormat,
    options: options ?? this.options,
    expectedAnswer: identical(expectedAnswer, _unset)
        ? this.expectedAnswer
        : expectedAnswer as String?,
    correctOptionIndex: identical(correctOptionIndex, _unset)
        ? this.correctOptionIndex
        : correctOptionIndex as int?,
  );
}

class Lesson {
  final String id;
  final String title;
  final String? subject;
  final String? topic;
  final String? gradeLevel;
  final List<LessonStep> steps;
  final int createdAtMs;

  /// Reserved for forward-compat with a future "unit" / multi-lesson plan
  /// grouping in the teacher app. Currently unused by the UI; safe to ignore.
  final String? unitId;

  Lesson({
    required this.id,
    required this.title,
    this.subject,
    this.topic,
    this.gradeLevel,
    required this.steps,
    required this.createdAtMs,
    this.unitId,
  });

  factory Lesson.create({
    required String title,
    String? subject,
    String? topic,
    String? gradeLevel,
    List<LessonStep> steps = const [],
    String? unitId,
  }) => Lesson(
    id: const Uuid().v4(),
    title: title,
    subject: subject,
    topic: topic,
    gradeLevel: gradeLevel,
    steps: steps,
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
    unitId: unitId,
  );

  factory Lesson.fromJson(Map<String, dynamic> j) => Lesson(
    id: j['id'] as String,
    title: j['title'] as String,
    subject: j['subject'] as String?,
    topic: j['topic'] as String?,
    gradeLevel: j['gradeLevel'] as String?,
    steps: ((j['steps'] as List?) ?? const [])
        .map((e) => LessonStep.fromJson(e as Map<String, dynamic>))
        .toList(),
    createdAtMs: j['createdAtMs'] as int,
    unitId: j['unitId'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (subject != null) 'subject': subject,
    if (topic != null) 'topic': topic,
    if (gradeLevel != null) 'gradeLevel': gradeLevel,
    'steps': steps.map((s) => s.toJson()).toList(),
    'createdAtMs': createdAtMs,
    if (unitId != null) 'unitId': unitId,
  };

  Lesson copyWith({
    String? title,
    Object? subject = _unset,
    Object? topic = _unset,
    Object? gradeLevel = _unset,
    List<LessonStep>? steps,
    Object? unitId = _unset,
  }) => Lesson(
    id: id,
    title: title ?? this.title,
    subject: identical(subject, _unset) ? this.subject : subject as String?,
    topic: identical(topic, _unset) ? this.topic : topic as String?,
    gradeLevel: identical(gradeLevel, _unset)
        ? this.gradeLevel
        : gradeLevel as String?,
    steps: steps ?? this.steps,
    createdAtMs: createdAtMs,
    unitId: identical(unitId, _unset) ? this.unitId : unitId as String?,
  );
}
