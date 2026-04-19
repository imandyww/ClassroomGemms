import 'dart:async';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:automation_core/automation_core.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';

import 'automation_dispatcher.dart';

typedef PendingPairCallback = Future<bool> Function(LanPeer candidate);

class AgentCore extends ChangeNotifier {
  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  LanAgentServer? server;
  LanAgentClient? client;
  AutomationService? automation;
  AutomationDispatcher? dispatcher;
  LmBootstrap? lmBoot;
  SttBootstrap? sttBoot;
  MicRecorder? recorder;
  PickedModel? loadedModel;
  bool sttReady = false;
  bool isRecording = false;
  ReactLoop? _react;

  final Map<String, LanPeer> _discovered = {};
  List<LanPeer> get discoveredPeers => _discovered.values.toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  List<LanPeer> get pairedPeers => pairing?.all() ?? const [];

  final List<String> log = [];
  final StreamController<LanPeer> pairRequests = StreamController.broadcast();

  String status = 'idle';

  void _append(String line) {
    log.add('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (log.length > 500) log.removeAt(0);
    status = line;
    notifyListeners();
  }

  Future<void> bootstrap({required PendingPairCallback onPendingPair}) async {
    _append('Loading device identity...');
    identity = await DeviceIdentity.loadOrCreate(defaultAlias: 'Agent-Mac');
    pairing = await PairingStore.open();
    automation = AutomationService(
      onStatusUpdate: _append,
      onScreenshotTaken: () => _append('screenshot ready'),
    );
    dispatcher = AutomationDispatcher(automation!);
    lmBoot = LmBootstrap(tier: DeviceTier.desktop);
    sttBoot = SttBootstrap();
    recorder = MicRecorder();
    client = LanAgentClient(identity: identity!);

    server = LanAgentServer(
      identity: identity!,
      pairing: pairing!,
      onIntent: _handleIntent,
      onPendingPair: (p) async {
        _append('Pair request from ${p.alias} @ ${p.ip} (${p.fingerprint.substring(0, 8)})');
        pairRequests.add(p);
        return onPendingPair(p);
      },
    );
    await server!.start();
    _append('Server listening on :${LanConst.port}');

    multicast = MulticastService(
      identity: identity!,
      onPeer: (peer) {
        _discovered[peer.fingerprint] = peer;
        notifyListeners();
      },
    );
    try {
      await multicast!.start();
      _append('Multicast discovery started');
    } catch (e) {
      _append('Multicast failed: $e (unicast still works)');
    }

    notifyListeners();
  }

  static const _systemPrompt = '''
You are a macOS automation agent. You receive high-level natural-language intents and satisfy them by calling the provided tools on the user's Mac.

Rules:
- Prefer keyboard shortcuts (pressKeys) over vision and mouse coordinates when possible. For example, use cmd+space to open Spotlight, cmd+t to open a new tab, etc.
- Break multi-step intents into a sequence of tool calls.
- When the intent is fully done, respond with a short natural-language summary and no tool calls.
- Keys for pressKeys must be UniversalKey enum names (e.g., "leftCommand", "space", "t", "return", "leftShift").
- If a tool returns {"success": false}, adapt: try an alternative approach or abort with an explanation.
''';

  Future<IntentResponse> _handleIntent(IntentRequest req, LanPeer from) async {
    _append('Intent from ${from.alias}: "${req.text}"');

    final d = dispatcher;
    final react = _react;
    if (loadedModel == null || react == null || d == null) {
      final note = 'Mac agent not ready: model not loaded. Load a model first.';
      _append(note);
      return IntentResponse(
        correlationId: req.correlationId,
        success: false,
        text: note,
        errorCode: 'not_ready',
      );
    }

    final run = await react.run(
      messages: [
        ChatMessage(role: 'system', content: _systemPrompt),
        ChatMessage(role: 'user', content: req.text),
      ],
      tools: d.buildTools(),
      dispatch: d.dispatch,
      onStatus: _append,
    );

    return IntentResponse(
      correlationId: req.correlationId,
      success: run.success,
      text: run.finalText,
      trace: run.trace,
    );
  }

  Future<void> loadModel() async {
    final boot = lmBoot;
    if (boot == null) return;
    try {
      final picked = await boot.ensureReady(onStatus: _append);
      loadedModel = picked;
      _react = ReactLoop(lm: boot.lm);
      notifyListeners();
    } catch (e) {
      _append('Model load failed: $e');
    }
  }

  Future<void> loadStt() async {
    final boot = sttBoot;
    if (boot == null) return;
    try {
      await boot.ensureReady(onStatus: _append);
      sttReady = true;
      notifyListeners();
    } catch (e) {
      _append('STT load failed: $e');
    }
  }

  Future<void> startRecording() async {
    final r = recorder;
    if (r == null) return;
    if (!await r.hasPermission()) {
      _append('Microphone permission denied.');
      return;
    }
    await r.start();
    isRecording = true;
    _append('Recording...');
    notifyListeners();
  }

  Future<String?> stopRecordingAndTranscribe() async {
    final r = recorder;
    final stt = sttBoot;
    if (r == null || stt == null) return null;
    String? path;
    try {
      _append('Stopping recorder...');
      path = await r.stop();
    } catch (e, st) {
      _append('Recorder stop failed: $e');
      debugPrint('$st');
      return null;
    } finally {
      isRecording = false;
      notifyListeners();
    }
    if (path == null) {
      _append('No audio captured (file missing or < 1KB).');
      return null;
    }
    _append('Captured audio at $path');
    if (!sttReady) {
      _append('STT not ready; loading now...');
      await loadStt();
      if (!sttReady) {
        _append('STT still not ready, aborting transcribe.');
        return null;
      }
    }
    try {
      _append('Transcribing...');
      final text = await stt.transcribeFile(path);
      _append('Transcript: "$text"');
      return text;
    } catch (e, st) {
      _append('Transcribe failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Run an intent locally (no LocalSend hop) — useful for testing on Mac
  /// without a paired phone.
  Future<IntentResponse> runLocal(String text) async {
    final id = identity;
    final req = IntentRequest.create(text: text, sourceDevice: id?.alias ?? 'local');
    return _handleIntent(req, LanPeer(
      alias: id?.alias ?? 'local',
      fingerprint: id?.fingerprint ?? 'local',
      ip: '127.0.0.1',
      port: LanConst.port,
      deviceType: 'desktop',
      lastSeen: DateTime.now(),
    ));
  }

  Future<IntentResponse?> sendTo(LanPeer peer, String text) async {
    final c = client;
    final id = identity;
    if (c == null || id == null) return null;
    _append('Sending "$text" to ${peer.alias} (${peer.ip})');
    final req = IntentRequest.create(text: text, sourceDevice: id.alias);
    final res = await c.sendIntent(peer: peer, request: req);
    if (res.success) {
      _append('<- ${res.response?.text}');
      return res.response;
    } else {
      _append('Send failed: ${res.error}');
      return null;
    }
  }

  @override
  void dispose() {
    multicast?.stop();
    server?.stop();
    pairRequests.close();
    super.dispose();
  }
}
