import 'package:agent_llm/agent_llm.dart';
import 'package:flutter/material.dart';
import 'package:lan_transport/lan_transport.dart';

import 'agent_core.dart';
import 'widgets/gradebook_pane.dart';
import 'widgets/lesson_authoring_pane.dart';
import 'widgets/library_pane.dart';
import 'widgets/live_class_pane.dart';
import 'widgets/setup_checklist.dart';
import 'widgets/teacher_chat_bar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TeacherApp());
}

class TeacherApp extends StatefulWidget {
  const TeacherApp({super.key});

  @override
  State<TeacherApp> createState() => _TeacherAppState();
}

class _TeacherAppState extends State<TeacherApp> {
  final core = AgentCore();
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
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
            title: const Text('Let this peer join?'),
            content: Text(
              '${candidate.alias}\nIP: ${candidate.ip}\nFingerprint: ${candidate.fingerprint.substring(0, 16)}...',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Accept'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorSchemeSeed: const Color(0xFF0F766E),
      useMaterial3: true,
    );
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Classroom Teacher',
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFFBF9F4),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFBF9F4),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: base.cardTheme.copyWith(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => _TeacherShell(core: core),
      ),
    );
  }
}

enum _Section { live, library, gradebook }

class _TeacherShell extends StatefulWidget {
  final AgentCore core;
  const _TeacherShell({required this.core});

  @override
  State<_TeacherShell> createState() => _TeacherShellState();
}

class _TeacherShellState extends State<_TeacherShell> {
  static final _demoEnabled = voiceAgentDemoSettings.enabled;
  final _localCtrl = TextEditingController(text: 'Open Spotlight.');
  String? _lastLocalReply;
  _Section _section = _Section.live;
  bool _ipsVisible = false;

  AgentCore get core => widget.core;

  @override
  void dispose() {
    _localCtrl.dispose();
    super.dispose();
  }

  Future<void> _runLocalIntent(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final res = await core.runLocal(trimmed);
    if (!mounted) return;
    setState(() => _lastLocalReply = res.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF14B8A6), Color(0xFF0F766E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0F766E).withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.school_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              core.identity == null
                  ? 'Classroom · booting'
                  : 'Classroom · ${core.identity!.alias}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        actions: [
          if (core.loadedModel == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: FilledButton.tonalIcon(
                onPressed: core.isModelLoading ? null : core.loadModel,
                icon: const Icon(Icons.download),
                label: Text(
                  core.isModelLoading
                      ? 'Loading Gemma...'
                      : (_demoEnabled
                            ? 'Load Preloaded Gemma-4-E2B'
                            : 'Load Gemma-4-E4B'),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Center(
                child: Text(
                  'Model: ${core.loadedModel!.slug}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          IconButton(
            tooltip: core.sttReady ? 'STT ready' : 'Load STT',
            icon: Icon(core.sttReady ? Icons.mic : Icons.mic_none),
            onPressed: core.loadStt,
          ),
          IconButton(
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.terminal),
            onPressed: _openAgentTools,
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section.index,
            onDestinationSelected: (i) =>
                setState(() => _section = _Section.values[i]),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.live_tv_outlined),
                selectedIcon: Icon(Icons.live_tv),
                label: Text('Live'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: Text('Library'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.grading_outlined),
                selectedIcon: Icon(Icons.grading),
                label: Text('Gradebook'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _sectionBody()),
                TeacherChatBar(core: core),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionBody() {
    switch (_section) {
      case _Section.live:
        return Column(
          children: [
            SetupChecklist(core: core),
            const Divider(height: 1),
            _connectionBanner(),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: LessonAuthoringPane(core: core)),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 4, child: LiveClassPane(core: core)),
                ],
              ),
            ),
          ],
        );
      case _Section.library:
        return LibraryPane(
          core: core,
          onSwitchToLive: () => setState(() => _section = _Section.live),
        );
      case _Section.gradebook:
        return GradebookPane(core: core);
    }
  }

  Widget _connectionBanner() {
    if (core.localIps.isEmpty && core.identity == null) {
      return const SizedBox.shrink();
    }
    final hasIps = core.localIps.isNotEmpty;
    final ipsText = !hasIps
        ? '(refreshing)'
        : _ipsVisible
            ? core.localIps.join(', ')
            : '••• hidden';
    return Container(
      width: double.infinity,
      color: Colors.teal.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.wifi, size: 14),
          const SizedBox(width: 6),
          Text(
            'Listening on :${LanConst.port}  •  IPs: ',
            style: const TextStyle(fontSize: 12),
          ),
          Expanded(
            child: Text(
              ipsText,
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasIps)
            IconButton(
              tooltip: _ipsVisible ? 'Hide IPs' : 'Show IPs',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              iconSize: 16,
              icon: Icon(
                _ipsVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() => _ipsVisible = !_ipsVisible),
            ),
        ],
      ),
    );
  }

  void _openAgentTools() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (_, sc) => AnimatedBuilder(
          animation: core,
          builder: (context, _) => ListView(
            controller: sc,
            padding: const EdgeInsets.all(16),
            children: [
              _pairingSettingsCard(),
              const SizedBox(height: 12),
              _localIntentPanel(),
              const SizedBox(height: 12),
              _peerPanel(),
              const SizedBox(height: 12),
              _logPane(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pairingSettingsCard() {
    return Card(
      child: SwitchListTile.adaptive(
        value: core.autoTrustPhoneSenders,
        onChanged: core.setAutoTrustPhoneSendersEnabled,
        title: const Text('Auto-trust iPhone senders'),
        subtitle: const Text(
          'If enabled, first-time voice_ios devices can send actions to this Mac without an approval dialog.',
        ),
      ),
    );
  }

  Widget _localIntentPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Local Intent (debug)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Run a macOS automation intent without hitting the LAN.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _localCtrl,
              decoration: const InputDecoration(
                labelText: 'Run intent locally',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _runLocalIntent(_localCtrl.text),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run'),
            ),
            if (_lastLocalReply != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                _lastLocalReply!,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _peerPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Peers', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Discovered'),
            if (core.discoveredPeers.isEmpty) const Text('(none yet)'),
            ...core.discoveredPeers.map(
              (p) => _peerTile(
                p,
                trusted: core.pairing?.isTrusted(p.fingerprint) ?? false,
              ),
            ),
            const SizedBox(height: 8),
            const Text('Paired'),
            if (core.pairedPeers.isEmpty) const Text('(none yet)'),
            ...core.pairedPeers.map((p) => _peerTile(p, trusted: true)),
          ],
        ),
      ),
    );
  }

  Widget _peerTile(LanPeer p, {required bool trusted}) {
    return ListTile(
      dense: true,
      title: Text('${p.alias} (${p.deviceType})'),
      subtitle: Text(
        '${p.ip}:${p.port} · ${p.fingerprint.substring(0, 8)}'
        '${trusted ? " · trusted" : ""}'
        '${p.acceptsIntents ? " · accepts intents" : " · send-only"}',
      ),
    );
  }

  Widget _logPane() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(8),
      child: SelectableText(
        core.log.isEmpty ? '(no events yet)' : core.log.join('\n'),
        style: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 11,
          color: Colors.greenAccent,
        ),
      ),
    );
  }
}
