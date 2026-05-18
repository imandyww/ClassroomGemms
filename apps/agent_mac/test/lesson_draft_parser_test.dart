import 'package:agent_mac/teacher_dispatcher.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LessonDraftParser', () {
    test('parses answer formats and multiple-choice options', () {
      final lesson = LessonDraftParser.tryParse(
        modelOutput: '''
Draft:
{
  "title": "Food Web Checks",
  "subject": "Science",
  "steps": [
    {
      "prompt": "Which organism is a producer?",
      "teacherNotes": "Look for plant vocabulary.",
      "expectedFormat": "multipleChoice",
      "options": ["Grass", "Rabbit", "Fox"]
    },
    {
      "prompt": "Name one thing energy does as it moves through the web.",
      "expectedFormat": "short"
    }
  ]
}
''',
        fallbackTitle: 'Fallback',
        topic: 'food webs',
        grade: '6th grade',
      );

      expect(lesson, isNotNull);
      expect(lesson!.title, 'Food Web Checks');
      expect(lesson.subject, 'Science');
      expect(lesson.steps, hasLength(2));
      expect(lesson.steps.first.expectedFormat, ExpectedFormat.multipleChoice);
      expect(lesson.steps.first.options, ['Grass', 'Rabbit', 'Fox']);
      expect(lesson.steps.first.teacherNotes, 'Look for plant vocabulary.');
      expect(lesson.steps[1].expectedFormat, ExpectedFormat.short);
    });

    test(
      'downgrades multiple choice without enough options to free response',
      () {
        final lesson = LessonDraftParser.tryParse(
          modelOutput: '''
{
  "title": "Incomplete Check",
  "steps": [
    {
      "prompt": "Pick the best answer.",
      "expectedFormat": "multipleChoice",
      "options": ["Only one"]
    }
  ]
}
''',
          fallbackTitle: 'Fallback',
          topic: 'formatting',
          grade: 'general',
        );

        expect(lesson, isNotNull);
        expect(lesson!.steps.single.expectedFormat, ExpectedFormat.free);
        expect(lesson.steps.single.options, isEmpty);
      },
    );
  });
}
