import 'package:flutter/material.dart';

import '../agent_core.dart';

class TeacherChatBar extends StatefulWidget {
  final AgentCore core;
  const TeacherChatBar({super.key, required this.core});

  @override
  State<TeacherChatBar> createState() => _TeacherChatBarState();
}

class _TeacherChatBarState extends State<TeacherChatBar> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  AgentCore get core => widget.core;

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
        color: Colors.white,
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (core.chatHistory.isNotEmpty) _history(),
          Row(
            children: [
              _modeToggle(),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled: core.loadedModel != null && !core.chatBusy,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: core.loadedModel == null
                        ? 'Load the model first'
                        : core.chatMode == TeacherChatMode.author
                            ? 'Ask the AI to draft, start, or summarize the lesson'
                            : 'Ask the AI to open an app, schedule, etc.',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: core.loadedModel == null || core.chatBusy ? null : _send,
                icon: core.chatBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _modeToggle() {
    return SegmentedButton<TeacherChatMode>(
      segments: const [
        ButtonSegment(
          value: TeacherChatMode.author,
          icon: Icon(Icons.school),
          label: Text('Author'),
        ),
        ButtonSegment(
          value: TeacherChatMode.automation,
          icon: Icon(Icons.terminal),
          label: Text('Mac'),
        ),
      ],
      selected: {core.chatMode},
      onSelectionChanged: (s) => core.setChatMode(s.first),
    );
  }

  Widget _history() {
    final lastTwo = core.chatHistory.length <= 2
        ? core.chatHistory
        : core.chatHistory.sublist(core.chatHistory.length - 2);
    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        controller: _scrollCtrl,
        reverse: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: lastTwo.map(_turnLine).toList(),
        ),
      ),
    );
  }

  Widget _turnLine(TeacherChatTurn turn) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('you: ${turn.userText}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          Text('AI: ${turn.replyText}', style: const TextStyle(fontSize: 11)),
          if (turn.trace.isNotEmpty)
            Text(
              'tools: ${turn.trace.map((t) => t.toolName).join(", ")}',
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    await core.sendTeacherChat(text);
  }
}
