import 'package:agent_mac/starter_lessons.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starter catalog covers multiple subjects with usable steps', () {
    expect(starterLessonTemplates, hasLength(greaterThanOrEqualTo(6)));
    expect(
      starterLessonSubjects,
      containsAll([
        'Computer Science',
        'English Language Arts',
        'Mathematics',
        'Science',
        'Social Studies',
        'World Language',
      ]),
    );

    final ids = <String>{};
    for (final template in starterLessonTemplates) {
      expect(ids.add(template.id), isTrue, reason: 'Duplicate starter id.');
      expect(template.title.trim(), isNotEmpty);
      expect(template.subject.trim(), isNotEmpty);
      expect(template.topic.trim(), isNotEmpty);
      expect(template.gradeLevel.trim(), isNotEmpty);
      expect(template.steps, hasLength(greaterThanOrEqualTo(3)));

      for (final step in template.steps) {
        expect(step.prompt.trim(), isNotEmpty);
        if (step.expectedFormat == ExpectedFormat.multipleChoice) {
          expect(step.options, hasLength(greaterThanOrEqualTo(2)));
        } else {
          expect(step.options, isEmpty);
        }
      }
    }
  });

  test('starter templates instantiate editable lesson copies', () {
    final template = starterLessonTemplates.first;
    final first = template.toLesson();
    final second = template.toLesson();

    expect(first.id, isNot(second.id));
    expect(first.title, template.title);
    expect(first.subject, template.subject);
    expect(first.topic, template.topic);
    expect(first.gradeLevel, template.gradeLevel);
    expect(first.steps, hasLength(template.steps.length));
    expect(first.steps.map((step) => step.index), [0, 1, 2]);
    expect(first.steps.first.id, isNot(second.steps.first.id));
  });
}
