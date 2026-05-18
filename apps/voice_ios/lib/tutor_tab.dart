import 'package:flutter/material.dart';

import 'completed_lesson_store.dart';
import 'ios_core.dart';
import 'subject_palette.dart';

/// Standalone Tutor tab. Lists every subject the student has finished at least
/// one lesson in, then drops into [_TutorChatScreen] when the user picks one.
/// Independent from the per-step tutor on the active-class tab so dipping in
/// here doesn't disturb a lesson-in-progress.
class TutorTab extends StatelessWidget {
  final IosCore core;
  const TutorTab({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: core,
      builder: (_, _) {
        final grouped = core.completedLessonsBySubject();
        final subjects = grouped.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'Tutor',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          body: SafeArea(
            child: subjects.isEmpty
                ? _emptyState(context)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: subjects.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final subject = subjects[i];
                      final lessons = grouped[subject]!;
                      return _SubjectCard(
                        subject: subject,
                        lessons: lessons,
                        onTap: () => _openSubject(context, subject),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.psychology_alt_outlined,
              size: 56,
              color: Colors.black26,
            ),
            const SizedBox(height: 12),
            Text(
              'No completed lessons yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Finish a lesson with your teacher and it will show up here so you can keep practicing on your own.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  void _openSubject(BuildContext context, String subject) {
    core.startGeneralTutor(subject);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TutorChatScreen(core: core, subject: subject),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  final String subject;
  final List<CompletedLesson> lessons;
  final VoidCallback onTap;
  const _SubjectCard({
    required this.subject,
    required this.lessons,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = paletteForSubject(subject == 'General' ? null : subject);
    final count = lessons.length;
    final totalSteps = lessons.fold<int>(0, (a, l) => a + l.stepPrompts.length);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: palette.heroGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: palette.seed.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: palette.accentGradient,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: palette.seed.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Icon(palette.icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subject,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: palette.accent,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count lesson${count == 1 ? '' : 's'} · $totalSteps prompt${totalSteps == 1 ? '' : 's'} practiced',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.accent.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: palette.accent.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _TutorChatScreen extends StatefulWidget {
  final IosCore core;
  final String subject;
  const _TutorChatScreen({required this.core, required this.subject});

  @override
  State<_TutorChatScreen> createState() => _TutorChatScreenState();
}

class _TutorChatScreenState extends State<_TutorChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  IosCore get core => widget.core;

  @override
  void initState() {
    super.initState();
    core.addListener(_onCoreChange);
  }

  @override
  void dispose() {
    core.removeListener(_onCoreChange);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onCoreChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _send() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    _inputCtrl.clear();
    core.askGeneralTutor(text);
  }

  @override
  Widget build(BuildContext context) {
    final palette =
        paletteForSubject(widget.subject == 'General' ? null : widget.subject);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final history = core.generalTutorHistory;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: palette.accentGradient,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(palette.icon, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${widget.subject} tutor',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Reset conversation',
            icon: const Icon(Icons.refresh),
            onPressed: history.isEmpty ? null : core.clearGeneralTutorHistory,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: viewInsets),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Private practice — your teacher cannot see this. The tutor will not just hand over answers.',
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.accent.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: history.isEmpty
                    ? _emptyHint(palette)
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: history.length,
                        itemBuilder: (_, i) {
                          final m = history[i];
                          final isUser = m.role == 'user';
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.8,
                              ),
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? palette.tint
                                    : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                m.content,
                                style: TextStyle(
                                  color: isUser
                                      ? palette.accent
                                      : Colors.black87,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (core.generalTutorBusy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Tutor thinking...',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputCtrl,
                        enabled: !core.generalTutorBusy &&
                            core.loadedModel != null,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: core.loadedModel == null
                              ? 'Tutor model still loading...'
                              : 'Ask the ${widget.subject.toLowerCase()} tutor...',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: core.generalTutorBusy ? null : _send,
                      icon: const Icon(Icons.send),
                      style: IconButton.styleFrom(
                        backgroundColor: palette.seed,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(SubjectPalette palette) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(palette.icon, size: 48, color: palette.accent.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'Keep practicing ${widget.subject}',
              style: TextStyle(
                color: palette.accent,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try: "Give me a practice question.", "Quiz me on what we covered.", "Explain the trickiest one again."',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
