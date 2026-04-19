import 'package:flutter/material.dart';

import 'ios_core.dart';

void main() {
  runApp(const VoiceIosApp());
}

class VoiceIosApp extends StatefulWidget {
  const VoiceIosApp({super.key});

  @override
  State<VoiceIosApp> createState() => _VoiceIosAppState();
}

class _VoiceIosAppState extends State<VoiceIosApp> {
  final core = IosCore();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => core.bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voice_ios',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => _Home(core: core),
      ),
    );
  }
}

class _Home extends StatefulWidget {
  final IosCore core;
  const _Home({required this.core});

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _textCtrl = TextEditingController(text: 'Hello from my phone');
  final _manualIpCtrl = TextEditingController();

  IosCore get core => widget.core;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(core.identity?.alias ?? 'voice_ios')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Status: ${core.status}'),
              Text('Fingerprint: ${core.identity?.fingerprint.substring(0, 8) ?? "-"}'),
              const SizedBox(height: 12),
              Wrap(
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
              const SizedBox(height: 12),
              _pttButton(),
              const Divider(height: 32),
              const Text('Discovered Macs / peers:'),
              Expanded(child: _peerList()),
              _manualIpRow(),
              const SizedBox(height: 8),
              TextField(
                controller: _textCtrl,
                decoration: const InputDecoration(
                    labelText: 'Intent', border: OutlineInputBorder()),
                maxLines: 2,
              ),
              if (core.lastResponse != null) ...[
                const SizedBox(height: 8),
                const Text('Last response:', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(core.lastResponse!.text),
              ],
              const SizedBox(height: 12),
              _logPane(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pttButton() {
    final recording = core.isRecording;
    return GestureDetector(
      onTapDown: (_) => core.startRecording(),
      onTapUp: (_) async {
        final transcript = await core.stopRecordingAndTranscribe();
        if (transcript == null || transcript.trim().isEmpty) return;
        _textCtrl.text = transcript;
        final peer = core.preferredPeer;
        if (peer == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'No Mac peer found. Make sure agent_mac is running on the same Wi-Fi.'),
            ));
          }
          return;
        }
        final res = await core.sendIntentTo(peer, transcript);
        if (res == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Send to ${peer.alias} failed — see log.'),
          ));
        }
      },
      onTapCancel: () => core.stopRecordingAndTranscribe(),
      child: Container(
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: recording ? Colors.red.shade600 : Colors.deepPurple.shade400,
          borderRadius: BorderRadius.circular(36),
        ),
        child: Text(
          recording ? 'Recording — release to send' : 'Hold to talk',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
    );
  }

  Widget _peerList() {
    final peers = core.discoveredPeers;
    if (peers.isEmpty) {
      return const Center(child: Text('Searching... make sure Mac agent is running on same WiFi.'));
    }
    return ListView.separated(
      itemBuilder: (_, i) {
        final p = peers[i];
        return ListTile(
          leading: const Icon(Icons.desktop_mac),
          title: Text(p.alias),
          subtitle: Text('${p.ip}:${p.port}'),
          trailing: FilledButton.tonal(
            onPressed: () => core.sendIntentTo(p, _textCtrl.text),
            child: const Text('Send'),
          ),
        );
      },
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemCount: peers.length,
    );
  }

  Widget _manualIpRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _manualIpCtrl,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Mac IP (e.g., 192.168.1.5)',
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
                  ? 'Added $ip as a peer.'
                  : 'Could not reach $ip — check Mac is running and IP is right.'),
            ));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }

  Widget _logPane() {
    return Container(
      height: 100,
      padding: const EdgeInsets.all(6),
      color: Colors.black.withValues(alpha: 0.85),
      child: SingleChildScrollView(
        reverse: true,
        child: SelectableText(
          core.log.isEmpty ? '(log empty)' : core.log.join('\n'),
          style: const TextStyle(
              fontFamily: 'Menlo', fontSize: 10, color: Colors.greenAccent),
        ),
      ),
    );
  }
}
