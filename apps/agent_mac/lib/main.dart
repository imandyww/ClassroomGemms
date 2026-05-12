import 'package:flutter/material.dart';
import 'package:lan_transport/lan_transport.dart';

import 'agent_core.dart';
import 'widgets/lesson_authoring_pane.dart';
import 'widgets/live_class_pane.dart';
import 'widgets/teacher_chat_bar.dart';

void main() {
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
            title: const Text('Let this student join?'),
            content: Text(
                '${candidate.alias}\nIP: ${candidate.ip}\nFingerprint: ${candidate.fingerprint.substring(0, 16)}...'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Decline')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Admit')),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Classroom Teacher',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => _TeacherHome(core: core),
      ),
    );
  }
}

class _TeacherHome extends StatelessWidget {
  final AgentCore core;
  const _TeacherHome({required this.core});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(core.identity == null
            ? 'Classroom Teacher (booting)'
            : 'Classroom Teacher · ${core.identity!.alias}'),
        actions: [
          if (core.loadedModel == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: FilledButton.tonalIcon(
                onPressed: core.loadModel,
                icon: const Icon(Icons.download),
                label: const Text('Load Gemma-4-E4B'),
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
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.terminal),
            onPressed: () => _openLog(context),
          ),
        ],
      ),
      body: Column(
        children: [
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
          TeacherChatBar(core: core),
        ],
      ),
    );
  }

  Widget _connectionBanner() {
    if (core.localIps.isEmpty && core.identity == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      color: Colors.teal.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.wifi, size: 14),
          const SizedBox(width: 6),
          Text(
            'Listening on :${LanConst.port}  •  ',
            style: const TextStyle(fontSize: 12),
          ),
          Expanded(
            child: Text(
              core.localIps.isEmpty
                  ? 'IPs: (refreshing)'
                  : 'IPs: ${core.localIps.join(", ")}',
              style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _openLog(BuildContext context) {
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
              core.log.isEmpty ? '(no events yet)' : core.log.join('\n'),
              style: const TextStyle(
                  fontFamily: 'Menlo', fontSize: 11, color: Colors.greenAccent),
            ),
          ),
        ),
      ),
    );
  }
}
