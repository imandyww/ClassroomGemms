import 'package:flutter/material.dart';
import 'package:lan_transport/lan_transport.dart';

import 'agent_core.dart';

void main() {
  runApp(const AgentMacApp());
}

class AgentMacApp extends StatefulWidget {
  const AgentMacApp({super.key});

  @override
  State<AgentMacApp> createState() => _AgentMacAppState();
}

class _AgentMacAppState extends State<AgentMacApp> {
  final core = AgentCore();
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Kick off async bootstrap after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      core.bootstrap(onPendingPair: _confirmPair);
    });
  }

  Future<bool> _confirmPair(LanPeer candidate) async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return false;
    return await showDialog<bool>(
          context: ctx,
          builder: (ctx) => AlertDialog(
            title: const Text('Pair with peer?'),
            content: Text(
                '${candidate.alias}\nIP: ${candidate.ip}\nFingerprint: ${candidate.fingerprint.substring(0, 16)}...'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Decline')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Accept')),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'agent_mac',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => _HomeScreen(core: core),
      ),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  final AgentCore core;
  const _HomeScreen({required this.core});

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  final _sendCtrl = TextEditingController(text: 'Echo test from Mac');
  final _localCtrl = TextEditingController(text: 'Open Spotlight.');
  String? _lastLocalReply;

  AgentCore get core => widget.core;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(core.identity == null
            ? 'agent_mac (booting)'
            : 'agent_mac · ${core.identity!.alias}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: _leftColumn()),
            const VerticalDivider(width: 24),
            Expanded(flex: 4, child: _logPane()),
          ],
        ),
      ),
    );
  }

  Widget _leftColumn() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section('Status', [
            Text('Server: ${core.server == null ? "starting" : "listening :${LanConst.port}"}'),
            Text('Fingerprint: ${core.identity?.fingerprint.substring(0, 16) ?? "-"}...'),
            Text('Model: ${core.loadedModel?.slug ?? "(not loaded)"} via ${core.loadedModel?.sourceLabel ?? "-"}'),
          ]),
          _section('LLM', [
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: core.loadModel, child: const Text('Load Gemma-4-E4B')),
                FilledButton.tonal(
                  onPressed: core.loadStt,
                  child: Text(core.sttReady ? 'STT: ready' : 'Load STT'),
                ),
                FilledButton.tonal(
                  onPressed: core.isRecording
                      ? () async {
                          final t = await core.stopRecordingAndTranscribe();
                          if (t != null) _localCtrl.text = t;
                        }
                      : core.startRecording,
                  child: Text(core.isRecording ? 'Stop & transcribe' : 'Record'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _localCtrl,
              decoration: const InputDecoration(
                labelText: 'Run intent locally (no LocalSend)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 6),
            FilledButton.tonal(
              onPressed: core.loadedModel == null
                  ? null
                  : () async {
                      final res = await core.runLocal(_localCtrl.text);
                      setState(() => _lastLocalReply = res.text);
                    },
              child: const Text('Run via ReAct loop'),
            ),
            if (_lastLocalReply != null) ...[
              const SizedBox(height: 6),
              SelectableText(_lastLocalReply!, style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
            ],
          ]),
          _section('Discovered peers', [
            if (core.discoveredPeers.isEmpty) const Text('(none yet)'),
            ...core.discoveredPeers.map((p) => _peerTile(p, trusted: core.pairing?.isTrusted(p.fingerprint) ?? false)),
          ]),
          _section('Paired peers', [
            if (core.pairedPeers.isEmpty) const Text('(none yet — pair via an incoming request or send test below)'),
            ...core.pairedPeers.map((p) => _peerTile(p, trusted: true)),
          ]),
          _section('Send test', [
            TextField(
              controller: _sendCtrl,
              decoration: const InputDecoration(labelText: 'Intent text', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _sendToFirstPeer,
              child: const Text('Send to first discovered peer'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _peerTile(LanPeer p, {required bool trusted}) {
    return Card(
      child: ListTile(
        dense: true,
        title: Text('${p.alias} (${p.deviceType})'),
        subtitle: Text('${p.ip}:${p.port} · ${p.fingerprint.substring(0, 8)}${trusted ? " · trusted" : ""}'),
        trailing: IconButton(
          icon: const Icon(Icons.send),
          tooltip: 'Send intent',
          onPressed: () => core.sendTo(p, _sendCtrl.text),
        ),
      ),
    );
  }

  Future<void> _sendToFirstPeer() async {
    final peers = core.discoveredPeers;
    if (peers.isEmpty) return;
    await core.sendTo(peers.first, _sendCtrl.text);
  }

  Widget _logPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            color: Colors.black.withValues(alpha: 0.85),
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                core.log.isEmpty ? '(no events yet)' : core.log.join('\n'),
                style: const TextStyle(
                    fontFamily: 'Menlo', fontSize: 11, color: Colors.greenAccent),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary)),
          ),
          ...children,
        ],
      ),
    );
  }
}
