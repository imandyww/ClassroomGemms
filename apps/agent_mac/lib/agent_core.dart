import 'dart:async';
import 'dart:io';

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

  /// Non-loopback IPv4 addresses, so the user can read them off the UI and
  /// punch one into the iOS Simulator's "Connect to Mac" field (multicast
  /// doesn't cross the Simulator boundary).
  List<String> localIps = const [];

  Future<void> refreshLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final ips = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          ips.add(addr.address);
        }
      }
      localIps = ips;
      notifyListeners();
    } catch (e) {
      _append('refreshLocalIps failed: $e');
    }
  }

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

    // Best-effort: surface local IPs so user can type one on the iPhone.
    unawaited(refreshLocalIps());

    notifyListeners();
  }

  static String _buildSystemPrompt() {
    final now = DateTime.now();
    final iso =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    final weekday = weekdays[now.weekday - 1];
    return '''
You are a macOS automation agent. You receive high-level natural-language intents (often transcribed from a phone PTT button) and satisfy them by calling the provided tools on the user's Mac.

Today is $iso ($weekday). Use this to resolve relative dates the user mentions ("today", "tomorrow", "Thursday", "next Monday", "in two weeks") into absolute YYYY-MM-DD values. When the user says a weekday, pick the next occurrence of that weekday strictly after today.

Routing rules — pick the most direct tool, do not improvise:
- For ANY scheduling, reminder, appointment, prescription pickup, or "add to calendar" request → call `createCalendarEvent` ONCE with a clean title and a resolved ISO date. Do NOT open Calendar.app via Spotlight; do NOT click. Examples that match this rule: "Prescribed some medicine for pickup on Thursday", "Add dentist appointment next Tuesday at 2pm", "Remind me to call mom on Friday".
- For everything else, prefer keyboard shortcuts (`pressKeys`) over mouse/vision. Use cmd+space for Spotlight, cmd+t for new tab, etc.
- Keys for pressKeys must be UniversalKey enum names (e.g., "leftCommand", "space", "t", "return", "leftShift").
- Break multi-step intents into a sequence of tool calls.
- When the intent is fully done, respond with a short natural-language summary and NO tool calls.
- If a tool returns {"success": false}, adapt: try an alternative approach or abort with a clear explanation.

Calendar tool tips:
- Default startTime is 09:00 and durationMinutes is 30 — only override if the user gave a time.
- Set `notes` to the original user transcript so they can find context later.
- Title should be short and imperative ("Pick up prescription", "Doctor appointment"), not a full sentence.
''';
  }

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
        ChatMessage(role: 'system', content: _buildSystemPrompt()),
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
      path = await r.stop().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _append('Recorder stop timed out — resetting recorder.');
      // Flip UI state immediately; leak the zombie native recorder and swap
      // in a fresh Dart-side one so the next Record press works.
      isRecording = false;
      recorder = MicRecorder();
      notifyListeners();
      unawaited(r.dispose().catchError((_) {}));
      return null;
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
