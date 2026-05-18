import 'package:agent_mac/agent_core.dart';
import 'package:agent_mac/widgets/lesson_authoring_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('starter lessons can be loaded from the empty state', (
    tester,
  ) async {
    final core = AgentCore();
    addTearDown(core.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: core,
            builder: (_, _) => LessonAuthoringPane(core: core),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Browse starter lessons'));
    await tester.pumpAndSettle();

    expect(find.text('Starter lessons'), findsOneWidget);
    expect(find.text('Mathematics'), findsOneWidget);

    await tester.tap(find.text('Ratios in a Recipe'));
    await tester.pumpAndSettle();

    expect(core.currentLesson?.title, 'Ratios in a Recipe');
    expect(core.currentLesson?.subject, 'Mathematics');
    expect(core.currentLesson?.steps, hasLength(3));
    expect(find.text('Ratios in a Recipe'), findsOneWidget);
  });

  testWidgets('starter lessons can be filtered by subject', (tester) async {
    final core = AgentCore();
    addTearDown(core.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: core,
            builder: (_, _) => LessonAuthoringPane(core: core),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Browse starter lessons'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Science'));
    await tester.pumpAndSettle();

    expect(find.text('Energy Flow in Ecosystems'), findsOneWidget);
    expect(find.text('Ratios in a Recipe'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(find.text('Ratios in a Recipe'), findsOneWidget);
  });
}
