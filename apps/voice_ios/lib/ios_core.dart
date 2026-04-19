import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';

/// iOS-side client: discover Macs via multicast, send IntentRequests, no server.
class IosCore extends ChangeNotifier {
  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  LanAgentClient? client;
  LmBootstrap? lmBoot;
  SttBootstrap? sttBoot;
  MicRecorder? recorder;
  PickedModel? loadedModel;
  bool sttReady = false;
  bool isRecording = false;

  final Map<String, LanPeer> _discovered = {};
  List<LanPeer> get discoveredPeers => _discovered.values.toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// Best peer for forwarding a voice intent: prefer paired/trusted Macs, then
  /// any desktop peer, then the most recently seen peer of any kind.
  LanPeer? get preferredPeer {
    final peers = discoveredPeers;
    if (peers.isEmpty) return null;
    final trustedDesktop = peers.firstWhere(
      (p) => p.deviceType == 'desktop' && (pairing?.isTrusted(p.fingerprint) ?? false),
      orElse: () => peers.firstWhere(
        (p) => p.deviceType == 'desktop',
        orElse: () => peers.first,
      ),
    );
    return trustedDesktop;
  }

  final List<String> log = [];
  IntentResponse? lastResponse;
  String status = 'idle';

  void _append(String line) {
    log.add('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (log.length > 300) log.removeAt(0);
    status = line;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    identity = await DeviceIdentity.loadOrCreate(defaultAlias: 'iPhone-Agent');
    pairing = await PairingStore.open();
    client = LanAgentClient(identity: identity!);
    lmBoot = LmBootstrap(tier: DeviceTier.phone);
    sttBoot = SttBootstrap();
    recorder = MicRecorder();

    _append('Identity ready: ${identity!.alias} / ${identity!.fingerprint.substring(0, 8)}');

    multicast = MulticastService(
      identity: identity!,
      onPeer: (p) {
        final isNew = !_discovered.containsKey(p.fingerprint);
        _discovered[p.fingerprint] = p;
        if (isNew) _append('Discovered ${p.alias} @ ${p.ip}');
        notifyListeners();
      },
    );
    try {
      await multicast!.start();
      _append('Multicast listener up on :${LanConst.port}');
    } catch (e) {
      _append('Multicast failed: $e');
    }
    notifyListeners();
  }

  Future<void> loadModel() async {
    final boot = lmBoot;
    if (boot == null) return;
    try {
      loadedModel = await boot.ensureReady(onStatus: _append);
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
      path = await r.stop().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _append('Recorder stop timed out — resetting recorder.');
      isRecording = false;
      recorder = MicRecorder();
      notifyListeners();
      unawaited(r.dispose().catchError((_) {}));
      return null;
    } catch (e) {
      _append('Recorder stop failed: $e');
      isRecording = false;
      notifyListeners();
      return null;
    }
    isRecording = false;
    notifyListeners();
    if (path == null) {
      _append('No audio captured.');
      return null;
    }
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
    } catch (e) {
      _append('Transcribe failed: $e');
      return null;
    }
  }

  static const _forwardSystemPrompt = '''
You sit between the user's voice and a desktop automation agent. Your only job is to call the tool `forward_to_mac(intent)` with a clean, imperative restatement of what the user wants done on their Mac. Preserve all the user's details (app names, URLs, exact text to type) — do not summarize away content. Do not answer the user yourself; always call the tool.
''';

  static final _forwardTool = CactusTool(
    name: 'forward_to_mac',
    description: 'Forward a cleaned intent to the Mac agent for execution.',
    parameters: ToolParametersSchema(
      properties: {
        'intent': ToolParameter(
          type: 'string',
          description: 'Imperative description of the task to run on the Mac.',
          required: true,
        ),
      },
    ),
  );

  /// If an iOS model is loaded, run a one-shot tool-calling pass so Gemma can
  /// clean up the phrasing before forwarding. Otherwise, forward the raw text.
  Future<String> _normalizeIntent(String raw) async {
    final boot = lmBoot;
    if (boot == null || loadedModel == null) return raw;
    try {
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: _forwardSystemPrompt),
          ChatMessage(role: 'user', content: raw),
        ],
        params: CactusCompletionParams(
          tools: [_forwardTool],
          forceTools: true,
          maxTokens: 256,
        ),
      );
      if (result.toolCalls.isNotEmpty) {
        final call = result.toolCalls.first;
        final cleaned = call.arguments['intent'];
        if (cleaned is String && cleaned.trim().isNotEmpty) {
          _append('Normalized: "$cleaned"');
          return cleaned;
        }
      }
    } catch (e) {
      _append('Normalization failed: $e (forwarding raw text)');
    }
    return raw;
  }

  /// Manually add a Mac peer by IP, bypassing multicast. Useful when iOS is
  /// running in the Simulator (which can't cross multicast) or when the LAN
  /// drops UDP. Probes /api/localsend/v2/info to grab the peer's real
  /// fingerprint/alias before injecting it.
  Future<bool> addManualPeer(String ipInput) async {
    final ip = ipInput.trim();
    if (ip.isEmpty) {
      _append('addManualPeer: empty IP.');
      return false;
    }
    final uri = Uri.parse('http://$ip:${LanConst.port}/api/localsend/v2/info');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      _append('Probing $uri ...');
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) {
        _append('Manual probe failed: HTTP ${resp.statusCode}');
        return false;
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final peer = LanPeer(
        alias: (json['alias'] as String?) ?? 'Mac@$ip',
        fingerprint: (json['fingerprint'] as String?) ?? 'manual-$ip',
        ip: ip,
        port: (json['port'] as num?)?.toInt() ?? LanConst.port,
        deviceType: (json['deviceType'] as String?) ?? 'desktop',
        lastSeen: DateTime.now(),
      );
      _discovered[peer.fingerprint] = peer;
      _append('Added manual peer ${peer.alias} @ ${peer.ip}');
      notifyListeners();
      return true;
    } catch (e) {
      _append('Manual probe failed: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<IntentResponse?> sendIntentTo(LanPeer peer, String text) async {
    final c = client;
    final id = identity;
    if (c == null || id == null) return null;
    final normalized = await _normalizeIntent(text);
    _append('-> ${peer.alias}: $normalized');
    final req = IntentRequest.create(text: normalized, sourceDevice: id.alias);
    final res = await c.sendIntent(peer: peer, request: req);
    if (res.success) {
      lastResponse = res.response;
      _append('<- ${res.response?.text}');
      // Trust peer if the response came back — means they trusted us, so we trust them.
      if (!(pairing?.isTrusted(peer.fingerprint) ?? false)) {
        await pairing?.trust(peer);
      }
      notifyListeners();
      return res.response;
    } else {
      _append('Send failed: ${res.error}');
      notifyListeners();
      return null;
    }
  }

  @override
  void dispose() {
    multicast?.stop();
    super.dispose();
  }
}
