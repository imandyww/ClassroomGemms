import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';

import '../agent_core.dart';

class LessonAuthoringPane extends StatelessWidget {
  final AgentCore core;
  const LessonAuthoringPane({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    final lesson = core.currentLesson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 12, right: 12, bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.menu_book, color: Colors.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  lesson == null ? 'No lesson loaded' : lesson.title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (lesson != null)
                IconButton(
                  tooltip: 'Add step',
                  icon: const Icon(Icons.add),
                  onPressed: () => _addStep(context),
                ),
            ],
          ),
        ),
        if (lesson != null) _runControls(context),
        const Divider(height: 1),
        Expanded(
          child: lesson == null
              ? _emptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: lesson.steps.length,
                  itemBuilder: (_, i) => _stepTile(context, lesson.steps[i]),
                ),
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lightbulb_outline, size: 48, color: Colors.black26),
            const SizedBox(height: 12),
            const Text(
              'Ask the AI to draft a lesson, or add a step manually.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => _addStep(context, asNewLesson: true),
              icon: const Icon(Icons.add),
              label: const Text('Start a blank lesson'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _runControls(BuildContext context) {
    final lesson = core.currentLesson!;
    final canStart = lesson.steps.isNotEmpty && !core.lessonRunning;
    final canNext = core.lessonRunning &&
        core.currentStepIndex >= 0 &&
        core.currentStepIndex + 1 < lesson.steps.length;
    final canEnd = core.lessonRunning;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: canStart ? core.startLesson : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: canNext ? core.nextStepUi : null,
            icon: const Icon(Icons.skip_next),
            label: const Text('Next step'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: canEnd ? core.endLessonUi : null,
            icon: const Icon(Icons.stop),
            label: const Text('End'),
          ),
          const Spacer(),
          if (core.currentStepIndex >= 0)
            Text(
              'Step ${core.currentStepIndex + 1} / ${lesson.steps.length}',
              style: const TextStyle(color: Colors.black54),
            ),
        ],
      ),
    );
  }

  Widget _stepTile(BuildContext context, LessonStep step) {
    final isCurrent = step.index == core.currentStepIndex;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: isCurrent ? Colors.teal.shade50 : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isCurrent ? Colors.teal : Colors.teal.shade100,
          child: Text(
            '${step.index + 1}',
            style: TextStyle(
              color: isCurrent ? Colors.white : Colors.teal.shade900,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(step.prompt),
        subtitle: step.teacherNotes == null || step.teacherNotes!.isEmpty
            ? null
            : Text(
                'Notes: ${step.teacherNotes!}',
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Push this step',
              icon: const Icon(Icons.upload),
              onPressed: () => core.pushStep(step.index),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit),
              onPressed: () => _editStep(context, step),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addStep(BuildContext context, {bool asNewLesson = false}) async {
    final prompt = await _stepEditorDialog(context, initialText: '');
    if (prompt == null || prompt.trim().isEmpty) return;
    final lesson = core.currentLesson;
    if (asNewLesson || lesson == null) {
      final fresh = Lesson.create(
        title: 'Untitled lesson',
        steps: [LessonStep.create(index: 0, prompt: prompt.trim())],
      );
      core.replaceLesson(fresh);
    } else {
      final updated = lesson.copyWith(
        steps: [
          ...lesson.steps,
          LessonStep.create(index: lesson.steps.length, prompt: prompt.trim()),
        ],
      );
      core.replaceLesson(updated);
    }
  }

  Future<void> _editStep(BuildContext context, LessonStep step) async {
    final updated = await _stepEditorDialog(context, initialText: step.prompt);
    if (updated == null) return;
    final lesson = core.currentLesson;
    if (lesson == null) return;
    final newSteps = lesson.steps
        .map((s) => s.id == step.id ? s.copyWith(prompt: updated.trim()) : s)
        .toList();
    core.replaceLesson(lesson.copyWith(steps: newSteps));
  }

  Future<String?> _stepEditorDialog(BuildContext context, {required String initialText}) {
    final ctrl = TextEditingController(text: initialText);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(initialText.isEmpty ? 'New step' : 'Edit step'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Prompt the student will see',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
