import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../agent_core.dart';
import '../starter_lessons.dart';

/// Full-pane library of saved lessons. Subject filter chips, per-card actions
/// (Open in Live, Duplicate, Export JSON, Delete), plus Import / New blank /
/// Starter library entry points across the top.
class LibraryPane extends StatefulWidget {
  final AgentCore core;
  final VoidCallback onSwitchToLive;
  const LibraryPane({
    super.key,
    required this.core,
    required this.onSwitchToLive,
  });

  @override
  State<LibraryPane> createState() => _LibraryPaneState();
}

class _LibraryPaneState extends State<LibraryPane> {
  String? _filterSubject;
  final _searchCtrl = TextEditingController();

  AgentCore get core => widget.core;

  @override
  void initState() {
    super.initState();
    unawaited(core.refreshSavedLessons());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = core.savedLessons;
    final subjects = <String>{};
    for (final lesson in all) {
      final s = lesson.subject;
      if (s != null && s.isNotEmpty) subjects.add(s);
    }
    final query = _searchCtrl.text.trim().toLowerCase();
    final filtered = all.where((lesson) {
      if (_filterSubject != null && lesson.subject != _filterSubject) {
        return false;
      }
      if (query.isEmpty) return true;
      return lesson.title.toLowerCase().contains(query) ||
          (lesson.topic ?? '').toLowerCase().contains(query) ||
          (lesson.subject ?? '').toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        _filterRow(subjects),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? _emptyState()
              : LayoutBuilder(
                  builder: (context, c) {
                    final cols = (c.maxWidth / 280).floor().clamp(1, 4);
                    return GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 1.4,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _lessonCard(filtered[i]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Row(
        children: [
          const Icon(Icons.menu_book, color: Colors.teal),
          const SizedBox(width: 8),
          const Text(
            'Library',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search title / topic / subject',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: () => _openStarterLessons(context),
            icon: const Icon(Icons.auto_stories),
            label: const Text('Starters'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _importJson,
            icon: const Icon(Icons.file_upload),
            label: const Text('Import'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _newBlankLesson,
            icon: const Icon(Icons.add),
            label: const Text('New blank'),
          ),
        ],
      ),
    );
  }

  Widget _filterRow(Set<String> subjects) {
    if (subjects.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilterChip(
            label: const Text('All'),
            selected: _filterSubject == null,
            onSelected: (_) => setState(() => _filterSubject = null),
          ),
          ...subjects.map(
            (s) => FilterChip(
              label: Text(s),
              selected: _filterSubject == s,
              onSelected: (_) => setState(() {
                _filterSubject = _filterSubject == s ? null : s;
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 56, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              core.savedLessons.isEmpty
                  ? 'No saved lessons yet.\nDraft one in Live or pick a starter.'
                  : 'No lessons match the current filter.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _openStarterLessons(context),
              icon: const Icon(Icons.auto_stories),
              label: const Text('Browse starter lessons'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lessonCard(Lesson lesson) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await core.loadSavedLesson(lesson);
          widget.onSwitchToLive();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lesson.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (lesson.subject != null && lesson.subject!.isNotEmpty)
                    Chip(
                      label: Text(
                        lesson.subject!,
                        style: const TextStyle(fontSize: 11),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    _summaryLine(lesson),
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Open in Live',
                    icon: const Icon(Icons.play_arrow, size: 18),
                    onPressed: () async {
                      await core.loadSavedLesson(lesson);
                      widget.onSwitchToLive();
                    },
                  ),
                  IconButton(
                    tooltip: 'Duplicate',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => _duplicate(lesson),
                  ),
                  IconButton(
                    tooltip: 'Export JSON',
                    icon: const Icon(Icons.file_download, size: 18),
                    onPressed: () => _exportJson(lesson),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _confirmDelete(lesson),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _summaryLine(Lesson lesson) {
    final parts = <String>[
      '${lesson.steps.length} step${lesson.steps.length == 1 ? '' : 's'}',
    ];
    if (lesson.topic != null && lesson.topic!.isNotEmpty) {
      parts.add(lesson.topic!);
    }
    if (lesson.gradeLevel != null && lesson.gradeLevel!.isNotEmpty) {
      parts.add(lesson.gradeLevel!);
    }
    final d = DateTime.fromMillisecondsSinceEpoch(lesson.createdAtMs).toLocal();
    parts.add(
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
    );
    return parts.join(' · ');
  }

  Future<void> _newBlankLesson() async {
    final titleCtrl = TextEditingController(text: 'Untitled lesson');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New blank lesson'),
        content: TextField(
          controller: titleCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    titleCtrl.dispose();
    if (ok != true) return;
    final lesson = Lesson.create(
      title: titleCtrl.text.trim().isEmpty
          ? 'Untitled lesson'
          : titleCtrl.text.trim(),
      steps: const [],
    );
    core.replaceLesson(lesson);
    widget.onSwitchToLive();
  }

  Future<void> _duplicate(Lesson lesson) async {
    final copy = Lesson.create(
      title: '${lesson.title} (copy)',
      subject: lesson.subject,
      topic: lesson.topic,
      gradeLevel: lesson.gradeLevel,
      steps: lesson.steps
          .asMap()
          .entries
          .map(
            (e) => LessonStep.create(
              index: e.key,
              prompt: e.value.prompt,
              teacherNotes: e.value.teacherNotes,
              expectedFormat: e.value.expectedFormat,
              options: List<String>.from(e.value.options),
              expectedAnswer: e.value.expectedAnswer,
              correctOptionIndex: e.value.correctOptionIndex,
            ),
          )
          .toList(),
    );
    await core.updateLessonInPlace(copy);
    await core.refreshSavedLessons();
    if (mounted) setState(() {});
  }

  Future<void> _exportJson(Lesson lesson) async {
    final home = Platform.environment['HOME'] ?? '';
    final downloads = Directory(p.join(home, 'Downloads'));
    if (!await downloads.exists()) await downloads.create(recursive: true);
    final safe = lesson.title
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
    final file = File(
      p.join(
        downloads.path,
        'lesson-${safe.isEmpty ? lesson.id.substring(0, 8) : safe}.json',
      ),
    );
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(lesson.toJson()));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Exported to ${file.path}'),
        action: SnackBarAction(
          label: 'Copy path',
          onPressed: () => Clipboard.setData(ClipboardData(text: file.path)),
        ),
      ),
    );
  }

  Future<void> _importJson() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import lesson'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste a lesson JSON file path (anywhere on disk) or the JSON itself.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 8,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    final raw = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || raw.isEmpty) return;

    String body;
    if (raw.startsWith('{')) {
      body = raw;
    } else {
      try {
        body = await File(raw).readAsString();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read $raw: $e')),
        );
        return;
      }
    }
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final lesson = Lesson.fromJson(json);
      await core.updateLessonInPlace(lesson);
      await core.refreshSavedLessons();
      if (mounted) setState(() {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${lesson.title}".')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not parse lesson JSON: $e')),
      );
    }
  }

  Future<void> _confirmDelete(Lesson lesson) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this lesson?'),
        content: Text('"${lesson.title}" — saved sessions are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await core.deleteSavedLesson(lesson.id);
    if (mounted) setState(() {});
  }

  Future<void> _openStarterLessons(BuildContext context) async {
    String? selectedSubject;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final templates = starterLessonTemplates
              .where(
                (t) => selectedSubject == null || t.subject == selectedSubject,
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
                        (s) => FilterChip(
                          label: Text(s),
                          selected: selectedSubject == s,
                          onSelected: (_) =>
                              setState(() => selectedSubject = s),
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
                        final t = templates[i];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(t.subject.substring(0, 1)),
                          ),
                          title: Text(t.title),
                          subtitle: Text(
                            '${t.subject} · ${t.gradeLevel} · ${t.steps.length} steps',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            Navigator.pop(ctx);
                            core.replaceLesson(t.toLesson());
                            widget.onSwitchToLive();
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
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }
}

