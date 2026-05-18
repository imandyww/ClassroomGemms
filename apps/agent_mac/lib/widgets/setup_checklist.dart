import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_core.dart';

/// Top-of-screen status that surfaces every condition required before the
/// teacher can actually run a lesson. Once everything is green it collapses
/// to a single line; while anything is missing it expands so the teacher
/// can fix it without leaving the page.
class SetupChecklist extends StatefulWidget {
  final AgentCore core;
  const SetupChecklist({super.key, required this.core});

  @override
  State<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<SetupChecklist> {
  bool _userExpanded = false;
  bool _micRequested = false;

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();
    final firstUnmet = items.indexWhere((i) => i.severity != _Severity.ok);
    final allGreen = firstUnmet < 0;
    final expanded = _userExpanded;

    final accent = allGreen
        ? Colors.teal.shade700
        : (items.any((i) => i.severity == _Severity.blocker)
              ? Theme.of(context).colorScheme.error
              : Colors.orange.shade800);

    return Material(
      color: Colors.teal.shade50,
      child: InkWell(
        onTap: () => setState(() => _userExpanded = !_userExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    allGreen
                        ? Icons.check_circle
                        : Icons.error_outline,
                    color: accent,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      allGreen
                          ? 'Setup: ready — students can join now.'
                          : 'Setup (${items.where((i) => i.severity != _Severity.ok).length} item(s) need attention)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Colors.black54,
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 6),
                ...items.map(_itemRow),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<_Item> _buildItems() {
    final core = widget.core;
    final hasIp = core.localIps.isNotEmpty;
    final modelReady = core.loadedModel != null;
    final sttReady = core.sttReady;
    final studentsConnected = core.roster.isNotEmpty;
    return [
      _Item(
        label: 'Device identity',
        severity:
            core.identity == null ? _Severity.warning : _Severity.ok,
        detail: core.identity == null
            ? 'Booting...'
            : '${core.identity!.alias} · ${core.identity!.fingerprint.substring(0, 8)}',
      ),
      _Item(
        label: 'LAN server',
        severity: core.server == null ? _Severity.blocker : _Severity.ok,
        detail: core.server == null
            ? 'Not started'
            : 'Listening on :53317',
      ),
      _Item(
        label: 'Local network IP',
        severity: hasIp ? _Severity.ok : _Severity.warning,
        detail: hasIp
            ? core.localIps.join(', ')
            : 'No non-loopback IPv4. Check Wi-Fi/Ethernet.',
        actions: [
          if (hasIp)
            _Action(
              label: 'Copy IP',
              icon: Icons.copy,
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: core.localIps.first),
                );
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied ${core.localIps.first}')),
                );
              },
            ),
          _Action(
            label: 'Recheck',
            icon: Icons.refresh,
            onPressed: core.refreshLocalIps,
          ),
        ],
      ),
      _Item(
        label: 'Microphone permission',
        severity: _micRequested ? _Severity.ok : _Severity.warning,
        detail: _micRequested
            ? 'Granted (or requested this session)'
            : 'Click "Request" so macOS can prompt for the mic.',
        actions: [
          _Action(
            label: 'Request',
            icon: Icons.mic,
            onPressed: () async {
              final ok = await core.ensureMicrophonePermission();
              if (mounted) setState(() => _micRequested = ok);
            },
          ),
        ],
      ),
      _Item(
        label: 'Tutor / lesson model (LLM)',
        severity: modelReady ? _Severity.ok : _Severity.blocker,
        detail: modelReady
            ? 'Loaded: ${core.loadedModel!.slug}'
            : (core.isModelLoading
                ? 'Loading...'
                : 'Not loaded — tap "Load model".'),
        actions: [
          if (!modelReady)
            _Action(
              label: core.isModelLoading ? 'Loading...' : 'Load model',
              icon: Icons.download,
              onPressed: core.isModelLoading ? null : core.loadModel,
            ),
        ],
      ),
      _Item(
        label: 'Speech-to-text',
        severity: sttReady ? _Severity.ok : _Severity.warning,
        detail: sttReady ? 'Ready' : 'Not loaded (optional for grading).',
        actions: [
          if (!sttReady)
            _Action(
              label: 'Load STT',
              icon: Icons.hearing,
              onPressed: core.loadStt,
            ),
        ],
      ),
      _Item(
        label: 'Students connected',
        severity: studentsConnected ? _Severity.ok : _Severity.warning,
        detail: studentsConnected
            ? '${core.roster.length} on the roster'
            : 'No students yet. They\'ll appear here when their app connects.',
      ),
    ];
  }

  Widget _itemRow(_Item item) {
    final dotColor = switch (item.severity) {
      _Severity.ok => Colors.teal.shade600,
      _Severity.warning => Colors.orange.shade700,
      _Severity.blocker => Theme.of(context).colorScheme.error,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (item.severity) {
              _Severity.ok => Icons.check_circle,
              _Severity.warning => Icons.warning_amber_rounded,
              _Severity.blocker => Icons.error,
            },
            color: dotColor,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  item.detail,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
          if (item.actions.isNotEmpty)
            Wrap(
              spacing: 4,
              children: item.actions
                  .map(
                    (a) => TextButton.icon(
                      onPressed: a.onPressed,
                      icon: Icon(a.icon, size: 14),
                      label: Text(
                        a.label,
                        style: const TextStyle(fontSize: 11),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
        ],
      ),
    );
  }
}

enum _Severity { ok, warning, blocker }

class _Item {
  final String label;
  final String detail;
  final _Severity severity;
  final List<_Action> actions;
  const _Item({
    required this.label,
    required this.detail,
    required this.severity,
    this.actions = const [],
  });
}

class _Action {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const _Action({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
}
