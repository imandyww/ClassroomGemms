import 'package:flutter/material.dart';

import '../agent_core.dart';

class LiveClassPane extends StatelessWidget {
  final AgentCore core;
  const LiveClassPane({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    final slots = core.roster.values.toList()
      ..sort((a, b) => a.peer.alias.compareTo(b.peer.alias));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 12, right: 12, bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.groups, color: Colors.teal),
              const SizedBox(width: 8),
              Text(
                'Class (${slots.length})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (core.currentStepIndex >= 0 && core.currentLesson != null)
                Text(
                  _answeredSummary(slots),
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: slots.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No students connected yet.\nMake sure they have the student app open on the same Wi-Fi.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: slots.length,
                  itemBuilder: (_, i) => _slotTile(slots[i]),
                ),
        ),
      ],
    );
  }

  String _answeredSummary(List<StudentSlot> slots) {
    final answered = slots.where((s) => s.state == StudentSessionState.answered).length;
    return '$answered / ${slots.length} answered';
  }

  Widget _slotTile(StudentSlot slot) {
    final resp = slot.lastResponse;
    final hasResponse = resp != null && resp.stepId ==
        (core.currentLesson != null && core.currentStepIndex >= 0
            ? core.currentLesson!.steps[core.currentStepIndex].id
            : null);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ExpansionTile(
        leading: _statePill(slot.state),
        title: Text(slot.peer.alias),
        subtitle: Text(
          '${slot.peer.ip} · ${slot.peer.fingerprint.substring(0, 8)}',
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (hasResponse)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resp.text,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (resp.audioWasUsed)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(Icons.mic, size: 12, color: Colors.black45),
                        ),
                      Text(
                        '${resp.text.length} chars',
                        style: const TextStyle(fontSize: 10, color: Colors.black45),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else
            const Text('(no response for this step yet)',
                style: TextStyle(fontStyle: FontStyle.italic, color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _statePill(StudentSessionState state) {
    Color c;
    IconData icon;
    switch (state) {
      case StudentSessionState.connected:
        c = Colors.blueGrey;
        icon = Icons.circle_outlined;
        break;
      case StudentSessionState.answering:
        c = Colors.orange;
        icon = Icons.edit_note;
        break;
      case StudentSessionState.answered:
        c = Colors.green;
        icon = Icons.check_circle;
        break;
      case StudentSessionState.disconnected:
        c = Colors.red;
        icon = Icons.cloud_off;
        break;
    }
    return Icon(icon, color: c);
  }
}
