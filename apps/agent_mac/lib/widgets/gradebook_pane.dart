import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';

import '../agent_core.dart';
import '../csv_export.dart';

/// Two-pane gradebook: session list (left) + per-session student-by-step
/// matrix (right). Click a cell to open a grading sheet with "Suggest grade"
/// (AI), a comment field, and a grade radio.
class GradebookPane extends StatefulWidget {
  final AgentCore core;
  const GradebookPane({super.key, required this.core});

  @override
  State<GradebookPane> createState() => _GradebookPaneState();
}

class _GradebookPaneState extends State<GradebookPane> {
  String? _selectedSessionId;

  AgentCore get core => widget.core;

  @override
  void initState() {
    super.initState();
    unawaited(core.refreshSavedSessions());
  }

  @override
  Widget build(BuildContext context) {
    final sessions = [
      if (core.currentSession != null) core.currentSession!,
      ...core.savedSessions.where((s) => s.id != core.currentSession?.id),
    ];
    SessionRecord? selected;
    if (sessions.isNotEmpty) {
      selected = sessions.firstWhere(
        (s) => s.id == _selectedSessionId,
        orElse: () => sessions.first,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _sessionList(sessions, selected),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No sessions yet.\nStart a lesson in Live to populate the gradebook.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                )
              : _sessionDetail(selected),
        ),
      ],
    );
  }

  Widget _sessionList(List<SessionRecord> sessions, SessionRecord? selected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              const Icon(Icons.grading, color: Colors.teal),
              const SizedBox(width: 8),
              const Text(
                'Sessions',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () async {
                  await core.refreshSavedSessions();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '(no sessions)',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (_, i) {
                    final s = sessions[i];
                    final isLive = core.currentSession?.id == s.id;
                    return ListTile(
                      selected: selected?.id == s.id,
                      selectedTileColor: Colors.teal.shade50,
                      dense: true,
                      title: Text(
                        s.lessonTitleSnapshot,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _sessionSubtitle(s, isLive: isLive),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: !isLive
                          ? IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                              ),
                              onPressed: () => _confirmDelete(s),
                            )
                          : const Icon(
                              Icons.circle,
                              color: Colors.green,
                              size: 10,
                            ),
                      onTap: () => setState(() => _selectedSessionId = s.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _sessionSubtitle(SessionRecord s, {required bool isLive}) {
    final d = DateTime.fromMillisecondsSinceEpoch(s.startedAtMs).toLocal();
    final stamp =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final score = s.averageScore;
    final scoreText = score == null
        ? 'ungraded'
        : '${(score * 100).round()}% avg';
    return '${isLive ? 'LIVE · ' : ''}$stamp · ${s.students.length} student(s) · $scoreText';
  }

  Widget _sessionDetail(SessionRecord session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.lessonTitleSnapshot,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${session.students.length} students · ${session.lessonStepsSnapshot.length} steps · ${(session.gradingProgress * 100).round()}% graded',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _exportCsv(session),
                icon: const Icon(Icons.file_download, size: 18),
                label: const Text('Export CSV'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _matrix(session)),
      ],
    );
  }

  Widget _matrix(SessionRecord session) {
    final steps = session.lessonStepsSnapshot;
    final students = session.students;
    if (students.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No student responses captured for this session.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          headingRowHeight: 44,
          dataRowMinHeight: 44,
          dataRowMaxHeight: 64,
          columns: [
            const DataColumn(label: Text('Student')),
            for (var i = 0; i < steps.length; i++)
              DataColumn(
                label: SizedBox(
                  width: 100,
                  child: Text(
                    'Step ${i + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
          rows: [
            for (final student in students)
              DataRow(
                cells: [
                  DataCell(
                    SizedBox(
                      width: 200,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              student.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit, size: 14),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: 'Rename',
                            onPressed: () => _renameStudent(student),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final step in steps)
                    DataCell(
                      _matrixCell(session, student, step),
                      onTap: () => _openGradingSheet(session, student, step),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _matrixCell(
    SessionRecord session,
    SessionStudent student,
    LessonStep step,
  ) {
    final resp = session.responses.firstWhere(
      (r) => r.studentFingerprint == student.fingerprint && r.stepId == step.id,
      orElse: () => GradedResponse(
        studentFingerprint: student.fingerprint,
        studentAlias: student.alias,
        stepId: step.id,
        text: '',
        audioWasUsed: false,
        submittedAtMs: 0,
      ),
    );
    final hasResponse = resp.submittedAtMs > 0;
    final bg = _gradeColor(resp.grade);
    return Container(
      width: 100,
      height: 40,
      decoration: BoxDecoration(
        color: bg ?? (hasResponse ? Colors.grey.shade100 : null),
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        hasResponse
            ? (resp.grade == null
                ? _truncate(resp.text, 14)
                : gradeToString(resp.grade!))
            : '—',
        style: TextStyle(
          fontSize: 11,
          fontWeight: resp.grade != null ? FontWeight.w600 : FontWeight.normal,
          color: bg == null ? Colors.black87 : Colors.black,
        ),
      ),
    );
  }

  Color? _gradeColor(Grade? g) {
    if (g == null) return null;
    switch (g) {
      case Grade.correct:
        return Colors.green.shade200;
      case Grade.partial:
        return Colors.amber.shade200;
      case Grade.incorrect:
        return Colors.red.shade200;
    }
  }

  String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  Future<void> _openGradingSheet(
    SessionRecord session,
    SessionStudent student,
    LessonStep step,
  ) async {
    final existingResponse = session.responses.firstWhere(
      (r) => r.studentFingerprint == student.fingerprint && r.stepId == step.id,
      orElse: () => GradedResponse(
        studentFingerprint: student.fingerprint,
        studentAlias: student.alias,
        stepId: step.id,
        text: '',
        audioWasUsed: false,
        submittedAtMs: 0,
      ),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GradingSheet(
        core: core,
        session: session,
        student: student,
        step: step,
        response: existingResponse,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _renameStudent(SessionStudent student) async {
    final ctrl = TextEditingController(text: student.displayName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename student'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Display name',
            helperText: 'Original alias: ${student.alias}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true) return;
    await core.setStudentDisplayName(student.fingerprint, name);
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(SessionRecord session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          '"${session.lessonTitleSnapshot}" with ${session.students.length} students. This cannot be undone.',
        ),
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
    await core.deleteSavedSession(session.id);
    if (mounted) {
      setState(() {
        if (_selectedSessionId == session.id) _selectedSessionId = null;
      });
    }
  }

  Future<void> _exportCsv(SessionRecord session) async {
    try {
      final result = await exportSessionCsv(session);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${result.rowCount} rows → ${result.path}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV export failed: $e')),
      );
    }
  }
}

/// Modal that lets the teacher inspect a single response, grade it, edit the
/// comment, and (optionally) ask the local LLM to suggest a grade.
class _GradingSheet extends StatefulWidget {
  final AgentCore core;
  final SessionRecord session;
  final SessionStudent student;
  final LessonStep step;
  final GradedResponse response;

  const _GradingSheet({
    required this.core,
    required this.session,
    required this.student,
    required this.step,
    required this.response,
  });

  @override
  State<_GradingSheet> createState() => _GradingSheetState();
}

class _GradingSheetState extends State<_GradingSheet> {
  late Grade? _grade;
  late TextEditingController _commentCtrl;
  bool _suggesting = false;
  String? _aiExplanation;

  @override
  void initState() {
    super.initState();
    _grade = widget.response.grade;
    _commentCtrl = TextEditingController(text: widget.response.gradeComment ?? '');
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasResponse = widget.response.submittedAtMs > 0;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, sc) => SingleChildScrollView(
        controller: sc,
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              widget.student.displayName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            Text(
              widget.session.lessonTitleSnapshot,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            const Text(
              'Question',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(widget.step.prompt),
            ),
            if (widget.step.expectedAnswer != null &&
                widget.step.expectedAnswer!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Expected answer (key)',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  widget.step.expectedAnswer!,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Student answer',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                hasResponse ? widget.response.text : '(no answer submitted)',
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: hasResponse
                      ? FontStyle.normal
                      : FontStyle.italic,
                  color: hasResponse ? Colors.black87 : Colors.black54,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text(
                  'Grade',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: hasResponse && !_suggesting ? _suggestGrade : null,
                  icon: _suggesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 16),
                  label: Text(
                    _suggesting ? 'Asking Gemma...' : 'Suggest grade',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (widget.step.expectedAnswer == null &&
                widget.step.expectedFormat != ExpectedFormat.multipleChoice)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'No expected answer set — add one in the lesson to enable AI grading.',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ),
            if (_aiExplanation != null) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.auto_awesome, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _aiExplanation!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                _gradeRadio(Grade.correct, 'Correct', Colors.green),
                _gradeRadio(Grade.partial, 'Partial', Colors.amber.shade800),
                _gradeRadio(Grade.incorrect, 'Incorrect', Colors.red),
                IconButton(
                  tooltip: 'Clear grade',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _grade = null;
                    _aiExplanation = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: hasResponse ? _saveGrade : null,
                  icon: const Icon(Icons.save),
                  label: const Text('Save grade'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gradeRadio(Grade g, String label, Color color) {
    final selected = _grade == g;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        label: Text(label),
        labelStyle: TextStyle(
          color: selected ? Colors.white : color,
          fontWeight: FontWeight.w600,
        ),
        selectedColor: color,
        onSelected: (_) => setState(() => _grade = g),
      ),
    );
  }

  Future<void> _suggestGrade() async {
    setState(() {
      _suggesting = true;
      _aiExplanation = null;
    });
    try {
      final suggestion = await widget.core.suggestGrade(
        step: widget.step,
        response: widget.response,
      );
      if (!mounted) return;
      if (suggestion == null) {
        setState(() {
          _aiExplanation =
              'Could not generate a suggestion (model not loaded, no expected answer, or JSON parse failed).';
        });
      } else {
        setState(() {
          _grade = suggestion.grade;
          _aiExplanation = suggestion.explanation;
        });
      }
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  Future<void> _saveGrade() async {
    await widget.core.setGrade(
      sessionId: widget.session.id,
      studentFingerprint: widget.student.fingerprint,
      stepId: widget.step.id,
      grade: _grade,
      source: _aiExplanation != null ? GradeSource.ai : GradeSource.teacher,
      comment: _commentCtrl.text.trim().isEmpty
          ? null
          : _commentCtrl.text.trim(),
    );
    if (mounted) Navigator.pop(context);
  }
}
