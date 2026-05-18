import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ios/ios_core.dart';
import 'package:voice_ios/student_lesson_page.dart';

void main() {
  testWidgets('multiple-choice prompts render selectable options', (
    tester,
  ) async {
    final core = IosCore()
      ..phase = StudentPhase.promptReceived
      ..currentPrompt = LessonPrompt(
        lessonId: 'lesson-1',
        stepId: 'step-1',
        stepIndex: 0,
        totalSteps: 1,
        text: 'Which organism is a producer?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: const ['Grass', 'Rabbit', 'Fox'],
        issuedAtMs: 123,
      );

    await tester.pumpWidget(MaterialApp(home: StudentLessonPage(core: core)));

    expect(find.text('Choose one'), findsOneWidget);
    expect(find.text('Grass'), findsOneWidget);
    expect(find.text('Rabbit'), findsOneWidget);
    expect(find.text('Fox'), findsOneWidget);

    await tester.tap(find.text('Grass'));
    await tester.pump();

    expect(core.draftText, 'Grass');
  });
}
