import 'package:flutter/material.dart';

import '../agent_core.dart';
import 'subject_palette.dart';

class LiveClassPane extends StatelessWidget {
  final AgentCore core;
  const LiveClassPane({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    final palette = paletteForSubject(core.currentLesson?.subject);
    final slots = core.roster.values.toList()
      ..sort((a, b) => a.peer.alias.compareTo(b.peer.alias));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(slots, palette),
        Expanded(
          child: slots.isEmpty
              ? _emptyState(palette)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: slots.length,
                  itemBuilder: (_, i) => _slotTile(slots[i], palette),
                ),
        ),
      ],
    );
  }

  Widget _header(List<StudentSlot> slots, SubjectPalette palette) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.groups_rounded, color: palette.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Text(
            'Class',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: palette.accent,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${slots.length}',
              style: TextStyle(
                color: palette.accent,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          const Spacer(),
          if (core.currentStepIndex >= 0 && core.currentLesson != null)
            Text(
              _answeredSummary(slots),
              style: TextStyle(
                color: palette.accent.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(SubjectPalette palette) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [palette.tint, palette.tint.withValues(alpha: 0.0)],
                ),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.school_rounded,
                size: 56,
                color: palette.seed.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'No students yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "They'll pop in here once the student app is open on the same Wi-Fi.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String _answeredSummary(List<StudentSlot> slots) {
    final answered = slots
        .where((s) => s.state == StudentSessionState.answered)
        .length;
    return '$answered / ${slots.length} answered';
  }

  Widget _slotTile(StudentSlot slot, SubjectPalette palette) {
    final resp = slot.lastResponse;
    final hasResponse = resp != null &&
        resp.stepId ==
            (core.currentLesson != null && core.currentStepIndex >= 0
                ? core.currentLesson!.steps[core.currentStepIndex].id
                : null);
    final avatarColor = colorForFingerprint(slot.peer.fingerprint);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.tint, width: 1),
        boxShadow: [
          BoxShadow(
            color: avatarColor.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Theme(
        data: ThemeData(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [avatarColor, avatarColor.withValues(alpha: 0.75)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  initialsFor(slot.peer.alias),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: _statusDot(slot.state),
              ),
            ],
          ),
          title: Text(
            slot.peer.alias,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
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
                  color: palette.tint.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(resp.text, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (resp.audioWasUsed)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.mic,
                              size: 12,
                              color: Colors.black45,
                            ),
                          ),
                        Text(
                          '${resp.text.length} chars',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.black45,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              const Text(
                '(no response for this step yet)',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.black54,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusDot(StudentSessionState state) {
    Color c;
    IconData icon;
    switch (state) {
      case StudentSessionState.connected:
        c = Colors.blueGrey;
        icon = Icons.circle;
        break;
      case StudentSessionState.answering:
        c = Colors.orange;
        icon = Icons.edit;
        break;
      case StudentSessionState.answered:
        c = Colors.green;
        icon = Icons.check;
        break;
      case StudentSessionState.disconnected:
        c = Colors.red;
        icon = Icons.cloud_off;
        break;
    }
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 9, color: Colors.white),
    );
  }
}
