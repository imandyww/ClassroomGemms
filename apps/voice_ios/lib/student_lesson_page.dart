import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';

import 'ios_core.dart';
import 'subject_palette.dart';

class StudentLessonPage extends StatefulWidget {
  final IosCore core;
  const StudentLessonPage({super.key, required this.core});

  @override
  State<StudentLessonPage> createState() => _StudentLessonPageState();
}

class _StudentLessonPageState extends State<StudentLessonPage> {
  final _answerCtrl = TextEditingController();

  IosCore get core => widget.core;

  @override
  void initState() {
    super.initState();
    core.addListener(_syncAnswerCtrl);
  }

  @override
  void dispose() {
    core.removeListener(_syncAnswerCtrl);
    _answerCtrl.dispose();
    super.dispose();
  }

  /// Pull model-side draftText into the field when it changes (voice append,
  /// new prompt). The field's onChanged pushes user keystrokes back to the
  /// model. Equality guard prevents the feedback loop.
  void _syncAnswerCtrl() {
    if (!mounted) return;
    if (_answerCtrl.text == core.draftText) return;
    _answerCtrl.text = core.draftText;
    _answerCtrl.selection = TextSelection.collapsed(
      offset: _answerCtrl.text.length,
    );
  }

  SubjectPalette get _palette =>
      paletteForSubject(core.currentPrompt?.subject);

  @override
  Widget build(BuildContext context) {
    final palette = _palette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _promptForName,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: palette.accentGradient,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: [
                      BoxShadow(
                        color: palette.seed.withValues(alpha: 0.28),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(palette.icon, color: Colors.white, size: 16),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    core.identity?.alias ?? 'Student',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.edit_outlined,
                  size: 14,
                  color: palette.accent.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.terminal),
            onPressed: _openDiagnostics,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _bodyForPhase(palette),
        ),
      ),
    );
  }

  Widget _bodyForPhase(SubjectPalette palette) {
    switch (core.phase) {
      case StudentPhase.bootingModel:
        return _bootingView(palette);
      case StudentPhase.waitingForTeacher:
      case StudentPhase.lessonStartedNoPrompt:
        return _waitingView(palette);
      case StudentPhase.promptReceived:
      case StudentPhase.answering:
      case StudentPhase.submitting:
      case StudentPhase.submitted:
        final prompt = core.currentPrompt;
        if (prompt == null) return _waitingView(palette);
        return _activePromptView(prompt, palette);
      case StudentPhase.lessonEnded:
        return _lessonEndedView(palette);
    }
  }

  Widget _bootingView(SubjectPalette palette) {
    return Column(
      children: [
        if (!core.hasUserSetName) ...[
          const SizedBox(height: 8),
          _NameSetupCard(core: core, palette: palette),
        ],
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(color: palette.seed),
                ),
                const SizedBox(height: 24),
                Text(
                  'Loading tutor model...',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  core.status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 24),
                if (core.loadedModel == null && !core.isModelLoading)
                  FilledButton.tonal(
                    onPressed: core.loadModel,
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _waitingView(SubjectPalette palette) {
    final lessonStarted = core.phase == StudentPhase.lessonStartedNoPrompt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!core.hasUserSetName) ...[
          const SizedBox(height: 8),
          _NameSetupCard(core: core, palette: palette),
        ],
        const SizedBox(height: 32),
        Center(
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [palette.tint, palette.tint.withValues(alpha: 0)],
              ),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                gradient: palette.accentGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: palette.seed.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.school_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          lessonStarted
              ? 'Lesson started!'
              : 'Waiting for the teacher...',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: palette.accent,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          lessonStarted
              ? 'Hang tight — the next prompt is on its way.'
              : 'They\'ll send the first prompt any second now.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: palette.accent.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 24),
        if (core.identity != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: palette.tint,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'You are ${core.identity!.alias}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          core.status,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
        const Spacer(),
        if (core.loadedModel == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: core.isModelLoading ? null : core.loadModel,
                  child: Text(
                    core.isModelLoading
                        ? 'Loading tutor...'
                        : 'Retry loading tutor',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _lessonEndedView(SubjectPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 56),
        Center(
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [palette.tint, palette.tint.withValues(alpha: 0)],
              ),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.celebration_rounded,
              size: 80,
              color: palette.seed,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Nice work!',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: palette.accent,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Lesson complete. The teacher will ping you when the next one starts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54),
        ),
      ],
    );
  }

  Widget _activePromptView(LessonPrompt prompt, SubjectPalette palette) {
    final isSubmitted = core.phase == StudentPhase.submitted;
    final isSubmitting = core.phase == StudentPhase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!core.hasUserSetName) ...[
          _NameSetupBanner(onTap: _promptForName, palette: palette),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette.tint,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${palette.shortLabel} · Step ${prompt.stepIndex + 1} / ${prompt.totalSteps}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: palette.accent,
                ),
              ),
            ),
            const Spacer(),
            _stepDots(prompt, palette),
          ],
        ),
        const SizedBox(height: 10),
        Container(
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
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(palette.icon, color: palette.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  prompt.text,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: palette.accent,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (isSubmitted) ...[
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFE6F4EA),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFB7DFBF)),
            ),
            padding: const EdgeInsets.all(14),
            child: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Color(0xFF15803D)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Submitted — waiting for the next step.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _openTutor,
            icon: const Icon(Icons.psychology_alt_outlined),
            label: const Text('Keep practicing with Tutor'),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.accent,
              side: BorderSide(color: palette.seed.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ] else ...[
          _answerInput(prompt, palette),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _micButton(palette)),
              const SizedBox(width: 8),
              _toolButton(
                icon: Icons.lightbulb_outline,
                label: 'Hint',
                onPressed: core.askHint,
                palette: palette,
              ),
              const SizedBox(width: 8),
              _toolButton(
                icon: Icons.psychology_alt,
                label: 'Tutor',
                onPressed: _openTutor,
                palette: palette,
              ),
            ],
          ),
          if (core.hintText != null) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb,
                    size: 16,
                    color: Color(0xFFB45309),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      core.hintText!,
                      style: const TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Color(0xFF78350F),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: isSubmitting ? null : core.submitAnswer,
              icon: const Icon(Icons.send_rounded),
              label: Text(
                isSubmitting ? 'Sending...' : 'Submit answer',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: palette.seed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
        const Spacer(),
        Text(
          core.status,
          style: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
      ],
    );
  }

  Widget _stepDots(LessonPrompt prompt, SubjectPalette palette) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(prompt.totalSteps, (i) {
        final isCurrent = i == prompt.stepIndex;
        final isDone = i < prompt.stepIndex;
        return Container(
          width: isCurrent ? 18 : 6,
          height: 6,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: isCurrent
                ? palette.seed
                : isDone
                    ? palette.seed.withValues(alpha: 0.6)
                    : palette.seed.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required SubjectPalette palette,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: palette.tint,
        foregroundColor: palette.accent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _answerInput(LessonPrompt prompt, SubjectPalette palette) {
    if (prompt.expectedFormat == ExpectedFormat.multipleChoice &&
        prompt.options.isNotEmpty) {
      final selected = core.draftText.trim();
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.tint),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose one',
              style: TextStyle(
                fontSize: 12,
                color: palette.accent.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: prompt.options.map((option) {
                final isSelected = selected == option;
                return GestureDetector(
                  onTap: () => core.updateDraft(option),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      gradient: isSelected ? palette.accentGradient : null,
                      color: isSelected ? null : palette.tint,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: palette.seed.withValues(alpha: 0.32),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      option,
                      style: TextStyle(
                        color: isSelected ? Colors.white : palette.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );
    }

    return TextField(
      controller: _answerCtrl,
      onChanged: core.updateDraft,
      maxLines: prompt.expectedFormat == ExpectedFormat.short ? 2 : 5,
      decoration: InputDecoration(
        labelText: 'Your answer',
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: palette.tint),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: palette.tint),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: palette.seed, width: 1.6),
        ),
        labelStyle: TextStyle(color: palette.accent.withValues(alpha: 0.8)),
      ),
    );
  }

  Widget _micButton(SubjectPalette palette) {
    final recording = core.isRecording;
    return GestureDetector(
      onTapDown: (_) => core.startRecording(),
      onTapUp: (_) => core.appendVoice(),
      onTapCancel: () => core.appendVoice(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: recording
              ? const LinearGradient(
                  colors: [Color(0xFFEF4444), Color(0xFFB91C1C)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : palette.accentGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: (recording ? const Color(0xFFEF4444) : palette.seed)
                  .withValues(alpha: 0.35),
              blurRadius: recording ? 14 : 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              recording ? Icons.fiber_manual_record : Icons.mic_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              recording ? 'Recording — release' : 'Hold to talk',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openTutor() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TutorSheet(core: core),
    );
  }

  Future<void> _promptForName() async {
    final current = core.identity?.alias ?? '';
    final ctrl = TextEditingController(
      text: core.hasUserSetName ? current : '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "This is the name your teacher will see in the gradebook.",
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(ctx, true),
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
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
    if (ok != true || name.isEmpty) return;
    await core.setStudentName(name);
  }

  void _openDiagnostics() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, sc) => _DiagnosticsPanel(core: core, scrollCtrl: sc),
      ),
    );
  }
}

class _TutorSheet extends StatefulWidget {
  final IosCore core;
  const _TutorSheet({required this.core});

  @override
  State<_TutorSheet> createState() => _TutorSheetState();
}

class _TutorSheetState extends State<_TutorSheet> {
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

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, sc) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: EdgeInsets.only(bottom: viewInsets),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.psychology_alt, color: Colors.deepPurple),
                  const SizedBox(width: 8),
                  const Text(
                    'Tutor (private)',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Reset conversation',
                    icon: const Icon(Icons.refresh),
                    onPressed: core.tutorHistory.isEmpty
                        ? null
                        : core.clearTutorHistory,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'The teacher cannot see this. The tutor will not give you the answer.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ),
            ),
            const Divider(height: 12),
            Expanded(
              child: core.tutorHistory.isEmpty
                  ? _emptyHint()
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      itemCount: core.tutorHistory.length,
                      itemBuilder: (_, i) {
                        final m = core.tutorHistory[i];
                        final isUser = m.role == 'user';
                        return Align(
                          alignment:
                              isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.8,
                            ),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? Colors.deepPurple.shade50
                                  : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(m.content),
                          ),
                        );
                      },
                    ),
            ),
            if (core.tutorBusy)
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
                      enabled: !core.tutorBusy && core.loadedModel != null,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: core.loadedModel == null
                            ? 'Tutor model still loading...'
                            : 'Ask the tutor anything about this step',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: core.tutorBusy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.psychology_alt_outlined,
              size: 48,
              color: Colors.black26,
            ),
            const SizedBox(height: 12),
            const Text(
              'Stuck? Ask the tutor a question.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 6),
            const Text(
              'Examples: "Why is this asking about X?", "Can you give me an analogy?", "What concept does this relate to?"',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  void _send() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    _inputCtrl.clear();
    core.askTutor(text);
  }
}

/// Slim "Tap to set your name" pill shown on the active-prompt view so a
/// student who joined mid-lesson can still rename themselves without digging
/// for the AppBar affordance.
class _NameSetupBanner extends StatelessWidget {
  final VoidCallback onTap;
  final SubjectPalette palette;
  const _NameSetupBanner({required this.onTap, required this.palette});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFCD34D)),
        ),
        child: Row(
          children: [
            const Icon(Icons.badge_outlined, size: 16, color: Color(0xFFB45309)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                "Tap to tell your teacher your name",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF78350F),
                ),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Color(0xFFB45309)),
          ],
        ),
      ),
    );
  }
}

/// Inline card shown on the booting/waiting screens until the student has
/// chosen a display name. Submitting the field calls [IosCore.setStudentName]
/// which persists the alias and re-broadcasts it on the LAN so the teacher's
/// gradebook picks it up.
class _NameSetupCard extends StatefulWidget {
  final IosCore core;
  final SubjectPalette palette;
  const _NameSetupCard({required this.core, required this.palette});

  @override
  State<_NameSetupCard> createState() => _NameSetupCardState();
}

class _NameSetupCardState extends State<_NameSetupCard> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    await widget.core.setStudentName(name);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return Container(
      decoration: BoxDecoration(
        gradient: palette.heroGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: palette.seed.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, color: palette.accent, size: 20),
              const SizedBox(width: 8),
              Text(
                "What's your name?",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: palette.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Your teacher will see this in their gradebook.',
            style: TextStyle(
              fontSize: 12,
              color: palette.accent.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    hintText: 'e.g., Maria',
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: palette.tint),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: palette.tint),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: palette.seed, width: 1.6),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.seed,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(_saving ? 'Saving...' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsPanel extends StatefulWidget {
  final IosCore core;
  final ScrollController scrollCtrl;
  const _DiagnosticsPanel({required this.core, required this.scrollCtrl});

  @override
  State<_DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<_DiagnosticsPanel> {
  final _ipCtrl = TextEditingController();

  IosCore get core => widget.core;

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: ListView(
        controller: widget.scrollCtrl,
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Diagnostics',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: core.isModelLoading ? null : core.loadModel,
                child: Text(
                  core.isModelLoading
                      ? 'Loading...'
                      : (core.loadedModel == null
                          ? 'Load tutor model'
                          : 'Model: ${core.loadedModel!.slug}'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: core.loadStt,
                child: Text(core.sttReady ? 'STT: ready' : 'Load STT'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: core.isScanningLan ? null : core.scanLanForPeers,
                child: Text(
                  core.isScanningLan ? 'Scanning...' : 'Rescan LAN',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Manually add teacher Mac by IP',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Teacher IP (e.g., 192.168.1.5)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Builder(
                builder: (innerCtx) => FilledButton.tonal(
                  onPressed: () async {
                    final ip = _ipCtrl.text.trim();
                    if (ip.isEmpty) return;
                    final ok = await core.addManualPeer(ip);
                    if (!innerCtx.mounted) return;
                    ScaffoldMessenger.of(innerCtx).showSnackBar(
                      SnackBar(
                        content: Text(
                          ok
                              ? 'Added $ip — waiting for prompts.'
                              : 'Could not reach $ip — check teacher is running.',
                        ),
                      ),
                    );
                  },
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Log',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              core.log.isEmpty ? '(log empty)' : core.log.join('\n'),
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: Colors.greenAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
