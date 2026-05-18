import 'package:agent_protocol/agent_protocol.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../agent_core.dart';
import '../starter_lessons.dart';
import 'subject_palette.dart';

class _StepDraft {
  final String prompt;
  final String? teacherNotes;
  final ExpectedFormat expectedFormat;
  final List<String> options;

  const _StepDraft({
    required this.prompt,
    this.teacherNotes,
    required this.expectedFormat,
    required this.options,
  });
}

class _ImportOptions {
  final String grade;
  final String hint;
  final int numSteps;
  const _ImportOptions({
    required this.grade,
    required this.hint,
    required this.numSteps,
  });
}

class LessonAuthoringPane extends StatelessWidget {
  final AgentCore core;
  const LessonAuthoringPane({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    final lesson = core.currentLesson;
    final palette = paletteForSubject(lesson?.subject);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _hero(context, lesson, palette),
        if (lesson != null) _runControls(context, palette),
        const SizedBox(height: 4),
        Expanded(
          child: lesson == null
              ? _emptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: lesson.steps.length,
                  itemBuilder: (_, i) =>
                      _stepTile(context, lesson.steps[i], palette),
                ),
        ),
      ],
    );
  }

  Widget _hero(BuildContext context, Lesson? lesson, SubjectPalette palette) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        gradient: palette.heroGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: palette.seed.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(palette.icon, color: palette.accent, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lesson == null ? 'No lesson loaded' : lesson.title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: palette.accent,
                    letterSpacing: -0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (lesson != null && _lessonContext(lesson).isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _lessonContext(lesson),
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.accent.withValues(alpha: 0.78),
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: core.importingFile
                ? (core.importStatus ?? 'Importing...')
                : 'Import PDF or image',
            icon: core.importingFile
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accent,
                    ),
                  )
                : const Icon(Icons.upload_file),
            color: palette.accent,
            onPressed: core.importingFile
                ? null
                : () => _importFromFile(context),
          ),
          IconButton(
            tooltip: 'Starter lessons',
            icon: const Icon(Icons.auto_stories),
            color: palette.accent,
            onPressed: () => _openStarterLessons(context),
          ),
          IconButton(
            tooltip: 'Saved lessons',
            icon: const Icon(Icons.folder_open),
            color: palette.accent,
            onPressed: () => _openSavedLessons(context),
          ),
          if (lesson != null)
            IconButton(
              tooltip: 'Add step',
              icon: const Icon(Icons.add),
              color: palette.accent,
              onPressed: () => _addStep(context),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lightbulb_outline,
              size: 48,
              color: Colors.black26,
            ),
            const SizedBox(height: 12),
            const Text(
              'Ask the AI to draft a lesson, browse starters, or add a step manually.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _openStarterLessons(context),
              icon: const Icon(Icons.auto_stories),
              label: const Text('Browse starter lessons'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: core.importingFile
                  ? null
                  : () => _importFromFile(context),
              icon: core.importingFile
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(
                core.importingFile
                    ? (core.importStatus ?? 'Importing...')
                    : 'Import PDF or image',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _addStep(context, asNewLesson: true),
              icon: const Icon(Icons.add),
              label: const Text('Start a blank lesson'),
            ),
            if (core.savedLessons.isNotEmpty) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _openSavedLessons(context),
                icon: const Icon(Icons.folder_open),
                label: const Text('Open saved lesson'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _runControls(BuildContext context, SubjectPalette palette) {
    final lesson = core.currentLesson!;
    final canStart = lesson.steps.isNotEmpty && !core.lessonRunning;
    final canNext =
        core.lessonRunning &&
        core.currentStepIndex >= 0 &&
        core.currentStepIndex + 1 < lesson.steps.length;
    final canEnd = core.lessonRunning;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: canStart ? core.startLesson : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Start'),
            style: FilledButton.styleFrom(
              backgroundColor: palette.seed,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: canNext ? core.nextStepUi : null,
            icon: const Icon(Icons.skip_next_rounded),
            label: const Text('Next step'),
            style: FilledButton.styleFrom(
              backgroundColor: palette.tint,
              foregroundColor: palette.accent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: canEnd ? core.endLessonUi : null,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('End'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const Spacer(),
          if (core.currentStepIndex >= 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: palette.tint,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Step ${core.currentStepIndex + 1} / ${lesson.steps.length}',
                style: TextStyle(
                  color: palette.accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepTile(
    BuildContext context,
    LessonStep step,
    SubjectPalette palette,
  ) {
    final isCurrent = step.index == core.currentStepIndex;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isCurrent
            ? palette.tint
            : palette.tint.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCurrent
              ? palette.seed.withValues(alpha: 0.6)
              : palette.tint,
          width: isCurrent ? 1.5 : 1,
        ),
        boxShadow: isCurrent
            ? [
                BoxShadow(
                  color: palette.seed.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isCurrent
                  ? [palette.seed, palette.accent]
                  : [Colors.white, palette.tint],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: palette.seed.withValues(alpha: isCurrent ? 0.35 : 0.12),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            '${step.index + 1}',
            style: TextStyle(
              color: isCurrent ? Colors.white : palette.accent,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
        ),
        title: Text(
          step.prompt,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: _stepSubtitle(step, palette),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Push this step',
              icon: const Icon(Icons.upload_rounded),
              color: palette.accent,
              onPressed: () => core.pushStep(step.index),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              color: palette.accent,
              onPressed: () => _editStep(context, step),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _stepSubtitle(LessonStep step, SubjectPalette palette) {
    final lines = <Widget>[];
    if (step.teacherNotes != null && step.teacherNotes!.isNotEmpty) {
      lines.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Notes: ${step.teacherNotes!}',
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          ),
        ),
      );
    }
    if (step.expectedFormat != ExpectedFormat.free || step.options.isNotEmpty) {
      lines.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: palette.seed.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _formatSummary(step),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.accent,
              ),
            ),
          ),
        ),
      );
    }
    if (lines.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }

  String _formatSummary(LessonStep step) {
    switch (step.expectedFormat) {
      case ExpectedFormat.short:
        return '✏️ short answer';
      case ExpectedFormat.multipleChoice:
        final suffix = step.options.isEmpty
            ? ''
            : ' · ${step.options.join(" / ")}';
        return '◯ multiple choice$suffix';
      case ExpectedFormat.free:
        return step.options.isEmpty
            ? '💭 free response'
            : step.options.join(' / ');
    }
  }

  Future<void> _addStep(
    BuildContext context, {
    bool asNewLesson = false,
  }) async {
    final draft = await _stepEditorDialog(context);
    if (draft == null) return;
    final step = LessonStep.create(
      index: 0,
      prompt: draft.prompt,
      teacherNotes: draft.teacherNotes,
      expectedFormat: draft.expectedFormat,
      options: draft.options,
    );
    final lesson = core.currentLesson;
    if (asNewLesson || lesson == null) {
      final fresh = Lesson.create(title: 'Untitled lesson', steps: [step]);
      core.replaceLesson(fresh);
    } else {
      final updated = lesson.copyWith(
        steps: [
          ...lesson.steps,
          LessonStep.create(
            index: lesson.steps.length,
            prompt: draft.prompt,
            teacherNotes: draft.teacherNotes,
            expectedFormat: draft.expectedFormat,
            options: draft.options,
          ),
        ],
      );
      core.replaceLesson(updated);
    }
  }

  Future<void> _editStep(BuildContext context, LessonStep step) async {
    final updated = await _stepEditorDialog(context, initialStep: step);
    if (updated == null) return;
    final lesson = core.currentLesson;
    if (lesson == null) return;
    final newSteps = lesson.steps
        .map(
          (s) => s.id == step.id
              ? s.copyWith(
                  prompt: updated.prompt,
                  teacherNotes: updated.teacherNotes,
                  expectedFormat: updated.expectedFormat,
                  options: updated.options,
                )
              : s,
        )
        .toList();
    core.replaceLesson(lesson.copyWith(steps: newSteps));
  }

  Future<_StepDraft?> _stepEditorDialog(
    BuildContext context, {
    LessonStep? initialStep,
  }) async {
    final promptCtrl = TextEditingController(text: initialStep?.prompt ?? '');
    final notesCtrl = TextEditingController(
      text: initialStep?.teacherNotes ?? '',
    );
    final optionsCtrl = TextEditingController(
      text: (initialStep?.options ?? const []).join('\n'),
    );
    var format = initialStep?.expectedFormat ?? ExpectedFormat.free;
    String? error;

    final result = await showDialog<_StepDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(initialStep == null ? 'New step' : 'Edit step'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: promptCtrl,
                    maxLines: 4,
                    autofocus: true,
                    onChanged: (_) => setState(() => error = null),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Prompt the student will see',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ExpectedFormat>(
                    initialValue: format,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Answer format',
                    ),
                    items: ExpectedFormat.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(_formatLabel(value)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        format = value;
                        error = null;
                      });
                    },
                  ),
                  if (format == ExpectedFormat.multipleChoice) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: optionsCtrl,
                      maxLines: 4,
                      onChanged: (_) => setState(() => error = null),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Options (one per line)',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Teacher notes (optional)',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final prompt = promptCtrl.text.trim();
                final options = format == ExpectedFormat.multipleChoice
                    ? _parseOptions(optionsCtrl.text)
                    : const <String>[];
                if (prompt.isEmpty) {
                  setState(() => error = 'Enter a prompt.');
                  return;
                }
                if (format == ExpectedFormat.multipleChoice &&
                    options.length < 2) {
                  setState(() => error = 'Add at least two options.');
                  return;
                }
                final notes = notesCtrl.text.trim();
                Navigator.of(ctx).pop(
                  _StepDraft(
                    prompt: prompt,
                    teacherNotes: notes.isEmpty ? null : notes,
                    expectedFormat: format,
                    options: options,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    promptCtrl.dispose();
    notesCtrl.dispose();
    optionsCtrl.dispose();
    return result;
  }

  Future<void> _importFromFile(BuildContext context) async {
    if (core.loadedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Model is still loading — wait until the Setup checklist clears, then try Import again.',
          ),
        ),
      );
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'],
      dialogTitle: 'Pick a PDF or image to turn into a lesson',
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    final options = await _importOptionsDialog(context, picked.files.single.name);
    if (options == null) return;
    final result = await core.importLessonFromFile(
      filePath: path,
      hint: options.hint,
      grade: options.grade,
      numSteps: options.numSteps,
    );
    if (!context.mounted) return;
    final success = result['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Imported "${result['title']}" (${result['numSteps']} steps).'
              : (result['message']?.toString() ?? 'Import failed.'),
        ),
      ),
    );
  }

  Future<_ImportOptions?> _importOptionsDialog(
    BuildContext context,
    String fileName,
  ) async {
    final hintCtrl = TextEditingController();
    final gradeCtrl = TextEditingController(text: '7th grade');
    var steps = 4;
    final result = await showDialog<_ImportOptions>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Import to lesson'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Source: $fileName',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: gradeCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Grade level / audience',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: hintCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Optional topic hint (e.g. "focus on photosynthesis")',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('Steps:'),
                    Expanded(
                      child: Slider(
                        value: steps.toDouble(),
                        min: 2,
                        max: 8,
                        divisions: 6,
                        label: '$steps',
                        onChanged: (v) => setState(() => steps = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$steps',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Gemma will read the file on-device and draft a lesson you can edit before pushing.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(
                _ImportOptions(
                  grade: gradeCtrl.text.trim().isEmpty
                      ? 'general audience'
                      : gradeCtrl.text.trim(),
                  hint: hintCtrl.text.trim(),
                  numSteps: steps,
                ),
              ),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Draft lesson'),
            ),
          ],
        ),
      ),
    );
    hintCtrl.dispose();
    gradeCtrl.dispose();
    return result;
  }

  Future<void> _openStarterLessons(BuildContext context) async {
    String? selectedSubject;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final templates = starterLessonTemplates
              .where(
                (template) =>
                    selectedSubject == null ||
                    template.subject == selectedSubject,
              )
              .toList();
          return AlertDialog(
            title: const Text('Starter lessons'),
            content: SizedBox(
              width: 640,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('All'),
                        selected: selectedSubject == null,
                        onSelected: (_) =>
                            setState(() => selectedSubject = null),
                      ),
                      ...starterLessonSubjects.map(
                        (subject) => FilterChip(
                          label: Text(subject),
                          selected: selectedSubject == subject,
                          onSelected: (_) =>
                              setState(() => selectedSubject = subject),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: templates.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final template = templates[i];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(template.subject.substring(0, 1)),
                          ),
                          title: Text(template.title),
                          subtitle: Text(_starterLessonSummary(template)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            core.replaceLesson(template.toLesson());
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openSavedLessons(BuildContext context) async {
    await core.refreshSavedLessons();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final lessons = core.savedLessons;
          return AlertDialog(
            title: const Text('Saved lessons'),
            content: SizedBox(
              width: 520,
              height: 420,
              child: lessons.isEmpty
                  ? const Center(child: Text('No saved lessons yet.'))
                  : ListView.separated(
                      itemCount: lessons.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final lesson = lessons[i];
                        return ListTile(
                          leading: const Icon(Icons.menu_book),
                          title: Text(lesson.title),
                          subtitle: Text(_lessonSummary(lesson)),
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await core.loadSavedLesson(lesson);
                          },
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await core.deleteSavedLesson(lesson.id);
                              if (ctx.mounted) setState(() {});
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _lessonSummary(Lesson lesson) {
    final parts = <String>[
      '${lesson.steps.length} step${lesson.steps.length == 1 ? "" : "s"}',
    ];
    if (lesson.subject != null && lesson.subject!.isNotEmpty) {
      parts.add(lesson.subject!);
    }
    if (lesson.topic != null && lesson.topic!.isNotEmpty) {
      parts.add(lesson.topic!);
    }
    if (lesson.gradeLevel != null && lesson.gradeLevel!.isNotEmpty) {
      parts.add(lesson.gradeLevel!);
    }
    final created = DateTime.fromMillisecondsSinceEpoch(
      lesson.createdAtMs,
    ).toLocal();
    parts.add(
      '${created.year}-${created.month.toString().padLeft(2, "0")}-${created.day.toString().padLeft(2, "0")}',
    );
    return parts.join(' - ');
  }

  String _starterLessonSummary(StarterLessonTemplate template) {
    return [
      template.subject,
      template.gradeLevel,
      template.topic,
      '${template.steps.length} steps',
    ].join(' - ');
  }

  String _lessonContext(Lesson lesson) {
    final parts = <String>[];
    if (lesson.subject != null && lesson.subject!.isNotEmpty) {
      parts.add(lesson.subject!);
    }
    if (lesson.topic != null && lesson.topic!.isNotEmpty) {
      parts.add(lesson.topic!);
    }
    if (lesson.gradeLevel != null && lesson.gradeLevel!.isNotEmpty) {
      parts.add(lesson.gradeLevel!);
    }
    return parts.join(' - ');
  }

  String _formatLabel(ExpectedFormat value) {
    switch (value) {
      case ExpectedFormat.free:
        return 'Free response';
      case ExpectedFormat.short:
        return 'Short answer';
      case ExpectedFormat.multipleChoice:
        return 'Multiple choice';
    }
  }

  List<String> _parseOptions(String raw) => raw
      .split('\n')
      .map((option) => option.trim())
      .where((option) => option.isNotEmpty)
      .toList(growable: false);
}
