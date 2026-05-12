import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';

import 'ios_core.dart';

class StudentLessonPage extends StatefulWidget {
  final IosCore core;
  const StudentLessonPage({super.key, required this.core});

  @override
  State<StudentLessonPage> createState() => _StudentLessonPageState();
}

class _StudentLessonPageState extends State<StudentLessonPage> {
  final _answerCtrl = TextEditingController();
  final _manualIpCtrl = TextEditingController();

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
    _manualIpCtrl.dispose();
    super.dispose();
  }

  /// Pull model-side draftText into the field when it changes (voice append,
  /// new prompt). The field's onChanged pushes user keystrokes back to the
  /// model. Equality guard prevents the feedback loop.
  void _syncAnswerCtrl() {
    if (!mounted) return;
    if (_answerCtrl.text == core.draftText) return;
    _answerCtrl.text = core.draftText;
    _answerCtrl.selection =
        TextSelection.collapsed(offset: _answerCtrl.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final prompt = core.currentPrompt;
    return Scaffold(
      appBar: AppBar(
        title: Text(core.identity?.alias ?? 'Student'),
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
          child: prompt == null ? _waitingView() : _activePromptView(prompt),
        ),
      ),
    );
  }

  Widget _waitingView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Icon(Icons.school, size: 64, color: Colors.deepPurple),
        const SizedBox(height: 16),
        const Text(
          'Waiting for the teacher to start a lesson...',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Text(
          'Status: ${core.status}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            FilledButton(
              onPressed: core.loadModel,
              child: Text(core.loadedModel == null
                  ? 'Load Gemma-4-E2B'
                  : 'LM: ${core.loadedModel!.slug}'),
            ),
            FilledButton.tonal(
              onPressed: core.loadStt,
              child: Text(core.sttReady ? 'STT: ready' : 'Load STT'),
            ),
          ],
        ),
        const Spacer(),
        const Divider(),
        const Text('Simulator? Add the teacher Mac manually:'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _manualIpCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Teacher IP (e.g., 127.0.0.1 or 192.168.1.5)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () async {
                final ip = _manualIpCtrl.text.trim();
                if (ip.isEmpty) return;
                final ok = await core.addManualPeer(ip);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok
                      ? 'Added $ip — waiting for prompts.'
                      : 'Could not reach $ip — check teacher is running.'),
                ));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _activePromptView(LessonPrompt prompt) {
    final isSubmitted = core.phase == StudentPhase.submitted;
    final isSubmitting = core.phase == StudentPhase.submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step ${prompt.stepIndex + 1} of ${prompt.totalSteps}',
          style: const TextStyle(color: Colors.black54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Card(
          color: Colors.deepPurple.shade50,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              prompt.text,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (isSubmitted)
          const Card(
            color: Color(0xFFE6F4EA),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 8),
                  Expanded(child: Text('Submitted — waiting for the next step.')),
                ],
              ),
            ),
          )
        else ...[
          TextField(
            controller: _answerCtrl,
            onChanged: core.updateDraft,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Your answer',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _micButton(),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: core.askHint,
                icon: const Icon(Icons.lightbulb_outline),
                label: const Text('Hint'),
              ),
            ],
          ),
          if (core.hintText != null) ...[
            const SizedBox(height: 8),
            Card(
              color: Colors.amber.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  core.hintText!,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: isSubmitting ? null : core.submitAnswer,
            icon: const Icon(Icons.send),
            label: Text(isSubmitting ? 'Sending...' : 'Submit answer'),
          ),
        ],
        const Spacer(),
        Text(
          'Status: ${core.status}',
          style: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
      ],
    );
  }

  Widget _micButton() {
    final recording = core.isRecording;
    return GestureDetector(
      onTapDown: (_) => core.startRecording(),
      onTapUp: (_) => core.appendVoice(),
      onTapCancel: () => core.appendVoice(),
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: recording ? Colors.red.shade600 : Colors.deepPurple.shade400,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mic, color: Colors.white),
            const SizedBox(width: 8),
            Text(
              recording ? 'Recording — release' : 'Hold to talk',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  void _openDiagnostics() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        builder: (_, sc) => Container(
          color: Colors.black,
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            controller: sc,
            child: SelectableText(
              core.log.isEmpty ? '(log empty)' : core.log.join('\n'),
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: Colors.greenAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
