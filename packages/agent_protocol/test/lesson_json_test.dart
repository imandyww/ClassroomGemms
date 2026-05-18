import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('JSON round-trip', () {
    test('LessonStep', () {
      final step = LessonStep.create(
        index: 2,
        prompt: 'What is photosynthesis?',
        teacherNotes: 'Look for chlorophyll mentions',
        expectedFormat: ExpectedFormat.short,
        options: const [],
      );
      final round = LessonStep.fromJson(
        jsonDecode(jsonEncode(step.toJson())) as Map<String, dynamic>,
      );
      expect(round.id, step.id);
      expect(round.index, 2);
      expect(round.prompt, step.prompt);
      expect(round.teacherNotes, 'Look for chlorophyll mentions');
      expect(round.expectedFormat, ExpectedFormat.short);
    });

    test('Lesson', () {
      final lesson = Lesson.create(
        title: 'Photosynthesis basics',
        subject: 'Science',
        topic: 'biology',
        gradeLevel: '7th',
        steps: [
          LessonStep.create(index: 0, prompt: 'Q1'),
          LessonStep.create(
            index: 1,
            prompt: 'Pick one',
            expectedFormat: ExpectedFormat.multipleChoice,
            options: const ['A', 'B', 'C'],
          ),
        ],
      );
      final round = Lesson.fromJson(
        jsonDecode(jsonEncode(lesson.toJson())) as Map<String, dynamic>,
      );
      expect(round.id, lesson.id);
      expect(round.title, 'Photosynthesis basics');
      expect(round.subject, 'Science');
      expect(round.topic, 'biology');
      expect(round.gradeLevel, '7th');
      expect(round.steps, hasLength(2));
      expect(round.steps[1].options, ['A', 'B', 'C']);
      expect(round.steps[1].expectedFormat, ExpectedFormat.multipleChoice);
    });

    test('optional lesson and step fields can be cleared', () {
      final lesson = Lesson.create(
        title: 'Photosynthesis basics',
        subject: 'Science',
        topic: 'biology',
        gradeLevel: '7th',
        steps: [
          LessonStep.create(
            index: 0,
            prompt: 'Q1',
            teacherNotes: 'Listen for vocabulary.',
          ),
        ],
      );

      final clearedLesson = lesson.copyWith(
        subject: null,
        topic: null,
        gradeLevel: null,
      );
      final clearedStep = lesson.steps.single.copyWith(teacherNotes: null);

      expect(clearedLesson.subject, isNull);
      expect(clearedLesson.topic, isNull);
      expect(clearedLesson.gradeLevel, isNull);
      expect(clearedStep.teacherNotes, isNull);
    });

    test('LessonPrompt', () {
      final step = LessonStep.create(index: 0, prompt: 'Hi');
      final prompt = LessonPrompt.fromStep(
        lessonId: 'L1',
        step: step,
        totalSteps: 3,
      );
      final round = LessonPrompt.fromJson(
        jsonDecode(jsonEncode(prompt.toJson())) as Map<String, dynamic>,
      );
      expect(round.lessonId, 'L1');
      expect(round.stepId, step.id);
      expect(round.stepIndex, 0);
      expect(round.totalSteps, 3);
      expect(round.text, 'Hi');
      expect(round.issuedAtMs, prompt.issuedAtMs);
    });

    test('StudentResponse', () {
      final resp = StudentResponse(
        lessonId: 'L1',
        stepId: 'S1',
        studentFingerprint: 'fp-abc',
        studentAlias: 'Alice',
        text: 'because chlorophyll',
        audioWasUsed: true,
        submittedAtMs: 12345,
      );
      final round = StudentResponse.fromJson(
        jsonDecode(jsonEncode(resp.toJson())) as Map<String, dynamic>,
      );
      expect(round.lessonId, 'L1');
      expect(round.stepId, 'S1');
      expect(round.studentFingerprint, 'fp-abc');
      expect(round.studentAlias, 'Alice');
      expect(round.text, 'because chlorophyll');
      expect(round.audioWasUsed, isTrue);
      expect(round.submittedAtMs, 12345);
    });

    test('ClassroomControl', () {
      final c = ClassroomControl.now(
        lessonId: 'L1',
        action: ControlAction.advanceStep,
        stepIndex: 2,
      );
      final round = ClassroomControl.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(round.lessonId, 'L1');
      expect(round.action, ControlAction.advanceStep);
      expect(round.stepIndex, 2);
      expect(round.issuedAtMs, c.issuedAtMs);
    });

    test('ClassroomEventBatch', () {
      final prompt = LessonPrompt(
        lessonId: 'L1',
        stepId: 'S1',
        stepIndex: 0,
        totalSteps: 2,
        text: 'Explain the evidence.',
        issuedAtMs: 1000,
      );
      final control = ClassroomControl(
        lessonId: 'L1',
        action: ControlAction.startLesson,
        issuedAtMs: 900,
      );
      final batch = ClassroomEventBatch(
        latestSequence: 2,
        events: [
          ClassroomEvent.control(sequence: 1, control: control),
          ClassroomEvent.prompt(sequence: 2, prompt: prompt),
        ],
      );

      final round = ClassroomEventBatch.fromJson(
        jsonDecode(jsonEncode(batch.toJson())) as Map<String, dynamic>,
      );

      expect(round.latestSequence, 2);
      expect(round.events, hasLength(2));
      expect(round.events[0].kind, ClassroomEventKind.control);
      expect(round.events[0].control!.action, ControlAction.startLesson);
      expect(round.events[1].kind, ClassroomEventKind.prompt);
      expect(round.events[1].prompt!.text, 'Explain the evidence.');
    });
  });
}
