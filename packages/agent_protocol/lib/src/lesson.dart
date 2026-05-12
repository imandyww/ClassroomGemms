import 'package:uuid/uuid.dart';

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

  LessonStep({
    required this.id,
    required this.index,
    required this.prompt,
    this.teacherNotes,
    this.expectedFormat = ExpectedFormat.free,
    this.options = const [],
  });

  factory LessonStep.create({
    required int index,
    required String prompt,
    String? teacherNotes,
    ExpectedFormat expectedFormat = ExpectedFormat.free,
    List<String> options = const [],
  }) =>
      LessonStep(
        id: const Uuid().v4(),
        index: index,
        prompt: prompt,
        teacherNotes: teacherNotes,
        expectedFormat: expectedFormat,
        options: options,
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
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'index': index,
        'prompt': prompt,
        if (teacherNotes != null) 'teacherNotes': teacherNotes,
        'expectedFormat': _formatToString(expectedFormat),
        'options': options,
      };

  LessonStep copyWith({
    int? index,
    String? prompt,
    String? teacherNotes,
    ExpectedFormat? expectedFormat,
    List<String>? options,
  }) =>
      LessonStep(
        id: id,
        index: index ?? this.index,
        prompt: prompt ?? this.prompt,
        teacherNotes: teacherNotes ?? this.teacherNotes,
        expectedFormat: expectedFormat ?? this.expectedFormat,
        options: options ?? this.options,
      );
}

class Lesson {
  final String id;
  final String title;
  final String? topic;
  final String? gradeLevel;
  final List<LessonStep> steps;
  final int createdAtMs;

  Lesson({
    required this.id,
    required this.title,
    this.topic,
    this.gradeLevel,
    required this.steps,
    required this.createdAtMs,
  });

  factory Lesson.create({
    required String title,
    String? topic,
    String? gradeLevel,
    List<LessonStep> steps = const [],
  }) =>
      Lesson(
        id: const Uuid().v4(),
        title: title,
        topic: topic,
        gradeLevel: gradeLevel,
        steps: steps,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  factory Lesson.fromJson(Map<String, dynamic> j) => Lesson(
        id: j['id'] as String,
        title: j['title'] as String,
        topic: j['topic'] as String?,
        gradeLevel: j['gradeLevel'] as String?,
        steps: ((j['steps'] as List?) ?? const [])
            .map((e) => LessonStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAtMs: j['createdAtMs'] as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (topic != null) 'topic': topic,
        if (gradeLevel != null) 'gradeLevel': gradeLevel,
        'steps': steps.map((s) => s.toJson()).toList(),
        'createdAtMs': createdAtMs,
      };

  Lesson copyWith({
    String? title,
    String? topic,
    String? gradeLevel,
    List<LessonStep>? steps,
  }) =>
      Lesson(
        id: id,
        title: title ?? this.title,
        topic: topic ?? this.topic,
        gradeLevel: gradeLevel ?? this.gradeLevel,
        steps: steps ?? this.steps,
        createdAtMs: createdAtMs,
      );
}
