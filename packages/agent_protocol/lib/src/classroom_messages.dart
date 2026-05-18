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
  final String? subject;

  LessonPrompt({
    required this.lessonId,
    required this.stepId,
    required this.stepIndex,
    required this.totalSteps,
    required this.text,
    this.expectedFormat = ExpectedFormat.free,
    this.options = const [],
    required this.issuedAtMs,
    this.subject,
  });

  factory LessonPrompt.fromStep({
    required String lessonId,
    required LessonStep step,
    required int totalSteps,
    String? subject,
  }) => LessonPrompt(
    lessonId: lessonId,
    stepId: step.id,
    stepIndex: step.index,
    totalSteps: totalSteps,
    text: step.prompt,
    expectedFormat: step.expectedFormat,
    options: step.options,
    issuedAtMs: DateTime.now().millisecondsSinceEpoch,
    subject: subject,
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
    subject: j['subject'] as String?,
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
    if (subject != null) 'subject': subject,
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
  }) => ClassroomControl(
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

enum ClassroomEventKind { prompt, control }

ClassroomEventKind _eventKindFromString(String s) {
  switch (s) {
    case 'prompt':
      return ClassroomEventKind.prompt;
    case 'control':
      return ClassroomEventKind.control;
    default:
      throw FormatException('unknown ClassroomEventKind: $s');
  }
}

String _eventKindToString(ClassroomEventKind kind) {
  switch (kind) {
    case ClassroomEventKind.prompt:
      return 'prompt';
    case ClassroomEventKind.control:
      return 'control';
  }
}

class ClassroomEvent {
  final int sequence;
  final ClassroomEventKind kind;
  final LessonPrompt? prompt;
  final ClassroomControl? control;

  ClassroomEvent._({
    required this.sequence,
    required this.kind,
    this.prompt,
    this.control,
  });

  factory ClassroomEvent.prompt({
    required int sequence,
    required LessonPrompt prompt,
  }) => ClassroomEvent._(
    sequence: sequence,
    kind: ClassroomEventKind.prompt,
    prompt: prompt,
  );

  factory ClassroomEvent.control({
    required int sequence,
    required ClassroomControl control,
  }) => ClassroomEvent._(
    sequence: sequence,
    kind: ClassroomEventKind.control,
    control: control,
  );

  factory ClassroomEvent.fromJson(Map<String, dynamic> j) {
    final kind = _eventKindFromString(j['kind'] as String);
    return switch (kind) {
      ClassroomEventKind.prompt => ClassroomEvent.prompt(
        sequence: (j['sequence'] as num).toInt(),
        prompt: LessonPrompt.fromJson(j['prompt'] as Map<String, dynamic>),
      ),
      ClassroomEventKind.control => ClassroomEvent.control(
        sequence: (j['sequence'] as num).toInt(),
        control: ClassroomControl.fromJson(
          j['control'] as Map<String, dynamic>,
        ),
      ),
    };
  }

  Map<String, dynamic> toJson() => {
    'sequence': sequence,
    'kind': _eventKindToString(kind),
    if (prompt != null) 'prompt': prompt!.toJson(),
    if (control != null) 'control': control!.toJson(),
  };
}

class ClassroomEventBatch {
  final int latestSequence;
  final List<ClassroomEvent> events;

  ClassroomEventBatch({required this.latestSequence, required this.events});

  factory ClassroomEventBatch.fromJson(Map<String, dynamic> j) =>
      ClassroomEventBatch(
        latestSequence: (j['latestSequence'] as num?)?.toInt() ?? 0,
        events: ((j['events'] as List?) ?? const [])
            .map((e) => ClassroomEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'latestSequence': latestSequence,
    'events': events.map((event) => event.toJson()).toList(),
  };
}
