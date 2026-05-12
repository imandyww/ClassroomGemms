import 'lesson.dart';

enum ControlAction { startLesson, advanceStep, endLesson, clearStep }

ControlAction _actionFromString(String s) {
  switch (s) {
    case 'startLesson':
      return ControlAction.startLesson;
    case 'advanceStep':
      return ControlAction.advanceStep;
    case 'endLesson':
      return ControlAction.endLesson;
    case 'clearStep':
      return ControlAction.clearStep;
    default:
      throw FormatException('unknown ControlAction: $s');
  }
}

String _actionToString(ControlAction a) {
  switch (a) {
    case ControlAction.startLesson:
      return 'startLesson';
    case ControlAction.advanceStep:
      return 'advanceStep';
    case ControlAction.endLesson:
      return 'endLesson';
    case ControlAction.clearStep:
      return 'clearStep';
  }
}

ExpectedFormat _expectedFromString(String? s) {
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

String _expectedToString(ExpectedFormat f) {
  switch (f) {
    case ExpectedFormat.short:
      return 'short';
    case ExpectedFormat.multipleChoice:
      return 'multipleChoice';
    case ExpectedFormat.free:
      return 'free';
  }
}

class LessonPrompt {
  final String lessonId;
  final String stepId;
  final int stepIndex;
  final int totalSteps;
  final String text;
  final ExpectedFormat expectedFormat;
  final List<String> options;
  final int issuedAtMs;

  LessonPrompt({
    required this.lessonId,
    required this.stepId,
    required this.stepIndex,
    required this.totalSteps,
    required this.text,
    this.expectedFormat = ExpectedFormat.free,
    this.options = const [],
    required this.issuedAtMs,
  });

  factory LessonPrompt.fromStep({
    required String lessonId,
    required LessonStep step,
    required int totalSteps,
  }) =>
      LessonPrompt(
        lessonId: lessonId,
        stepId: step.id,
        stepIndex: step.index,
        totalSteps: totalSteps,
        text: step.prompt,
        expectedFormat: step.expectedFormat,
        options: step.options,
        issuedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  factory LessonPrompt.fromJson(Map<String, dynamic> j) => LessonPrompt(
        lessonId: j['lessonId'] as String,
        stepId: j['stepId'] as String,
        stepIndex: j['stepIndex'] as int,
        totalSteps: j['totalSteps'] as int,
        text: j['text'] as String,
        expectedFormat: _expectedFromString(j['expectedFormat'] as String?),
        options: ((j['options'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        issuedAtMs: j['issuedAtMs'] as int,
      );

  Map<String, dynamic> toJson() => {
        'lessonId': lessonId,
        'stepId': stepId,
        'stepIndex': stepIndex,
        'totalSteps': totalSteps,
        'text': text,
        'expectedFormat': _expectedToString(expectedFormat),
        'options': options,
        'issuedAtMs': issuedAtMs,
      };
}

class StudentResponse {
  final String lessonId;
  final String stepId;
  final String studentFingerprint;
  final String studentAlias;
  final String text;
  final bool audioWasUsed;
  final int submittedAtMs;

  StudentResponse({
    required this.lessonId,
    required this.stepId,
    required this.studentFingerprint,
    required this.studentAlias,
    required this.text,
    required this.audioWasUsed,
    required this.submittedAtMs,
  });

  factory StudentResponse.fromJson(Map<String, dynamic> j) => StudentResponse(
        lessonId: j['lessonId'] as String,
        stepId: j['stepId'] as String,
        studentFingerprint: j['studentFingerprint'] as String,
        studentAlias: j['studentAlias'] as String,
        text: j['text'] as String,
        audioWasUsed: j['audioWasUsed'] as bool? ?? false,
        submittedAtMs: j['submittedAtMs'] as int,
      );

  Map<String, dynamic> toJson() => {
        'lessonId': lessonId,
        'stepId': stepId,
        'studentFingerprint': studentFingerprint,
        'studentAlias': studentAlias,
        'text': text,
        'audioWasUsed': audioWasUsed,
        'submittedAtMs': submittedAtMs,
      };
}

class ClassroomControl {
  final String lessonId;
  final ControlAction action;
  final int? stepIndex;
  final int issuedAtMs;

  ClassroomControl({
    required this.lessonId,
    required this.action,
    this.stepIndex,
    required this.issuedAtMs,
  });

  factory ClassroomControl.now({
    required String lessonId,
    required ControlAction action,
    int? stepIndex,
  }) =>
      ClassroomControl(
        lessonId: lessonId,
        action: action,
        stepIndex: stepIndex,
        issuedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  factory ClassroomControl.fromJson(Map<String, dynamic> j) => ClassroomControl(
        lessonId: j['lessonId'] as String,
        action: _actionFromString(j['action'] as String),
        stepIndex: j['stepIndex'] as int?,
        issuedAtMs: j['issuedAtMs'] as int,
      );

  Map<String, dynamic> toJson() => {
        'lessonId': lessonId,
        'action': _actionToString(action),
        if (stepIndex != null) 'stepIndex': stepIndex,
        'issuedAtMs': issuedAtMs,
      };
}
