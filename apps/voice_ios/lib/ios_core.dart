import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';

enum StudentPhase { idle, promptReceived, answering, submitting, submitted }

/// Student-side core: discover teacher Macs, host a small HTTP server that the
/// teacher pushes prompts/control to, capture voice + text answers, run them
/// through the on-device Gemma for cleanup, and POST them back.
class IosCore extends ChangeNotifier {
  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  LanAgentClient? client;
  LanAgentServer? server;
  LmBootstrap? lmBoot;
  SttBootstrap? sttBoot;
  MicRecorder? recorder;
  PickedModel? loadedModel;
  bool sttReady = false;
  bool isRecording = false;

  final Map<String, LanPeer> _discovered = {};
  List<LanPeer> get discoveredPeers => _discovered.values.toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  // --- classroom session state ---
  StudentPhase phase = StudentPhase.idle;
  LessonPrompt? currentPrompt;
  LanPeer? teacherPeer;
  String draftText = '';
  bool audioUsed = false;
  String? hintText;
  String? currentLessonId;

  final List<String> log = [];
  String status = 'idle';

  void _append(String line) {
    log.add('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (log.length > 300) log.removeAt(0);
    status = line;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    identity = await DeviceIdentity.loadOrCreate(defaultAlias: 'Student-${Platform.localHostname}');
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

    server = LanAgentServer(
      identity: identity!,
      pairing: pairing!,
      onPrompt: _handlePromptArrived,
      onControl: _handleControlArrived,
      // In a classroom the student trusts whatever teacher reaches them first;
      // there's no separate approval UI on the phone.
      onPendingPair: (peer) async {
        _append('Auto-trusting incoming teacher ${peer.alias}.');
        return true;
      },
    );
    try {
      await server!.start();
      _append('Student server listening on :${LanConst.port}');
    } catch (e) {
      _append('Server start failed: $e');
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

  Future<String?> _stopAndTranscribe() async {
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

  static const _cleanupSystemPrompt = '''
You are an editing assistant on a student's phone. The student just spoke an answer to a teacher's classroom prompt. Rewrite their transcript into a tighter version: remove filler ("um", "like", "you know"), fix obvious speech-to-text errors, keep the student's voice, and preserve every factual claim. Do not add information the student did not say. Return only the cleaned answer, no preamble.
''';

  /// Stop recording, transcribe with Whisper, run a one-shot Gemma cleanup,
  /// and append the result to the draft answer.
  Future<void> appendVoice() async {
    final transcript = await _stopAndTranscribe();
    if (transcript == null || transcript.trim().isEmpty) return;
    final cleaned = await _cleanupAnswer(transcript);
    audioUsed = true;
    draftText = draftText.isEmpty ? cleaned : '${draftText.trim()} $cleaned';
    if (phase == StudentPhase.promptReceived) phase = StudentPhase.answering;
    notifyListeners();
  }

  Future<String> _cleanupAnswer(String raw) async {
    final boot = lmBoot;
    if (boot == null || loadedModel == null) return raw;
    try {
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: _cleanupSystemPrompt),
          ChatMessage(role: 'user', content: raw),
        ],
        params: CactusCompletionParams(maxTokens: 256),
      );
      final cleaned = result.text.trim();
      if (cleaned.isEmpty) return raw;
      _append('Cleaned: "$cleaned"');
      return cleaned;
    } catch (e) {
      _append('Cleanup failed: $e (using raw transcript)');
      return raw;
    }
  }

  static const _hintSystemPrompt = '''
You are a hint helper running privately on a student's phone. The teacher cannot see what you say. The student is stuck on a classroom prompt. Give a single small nudge — a question, an analogy, or a recall of a related concept — that helps them think. Never give the answer outright. Keep it under two sentences.
''';

  /// Local-only: ask the on-device Gemma for a hint scoped to the current
  /// prompt + draft. Never sent to the teacher.
  Future<void> askHint() async {
    final boot = lmBoot;
    final prompt = currentPrompt;
    if (boot == null || loadedModel == null || prompt == null) {
      hintText = 'Hint unavailable (model not loaded).';
      notifyListeners();
      return;
    }
    hintText = '...thinking';
    notifyListeners();
    try {
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: _hintSystemPrompt),
          ChatMessage(
            role: 'user',
            content: 'Prompt: ${prompt.text}\nMy draft so far: $draftText',
          ),
        ],
        params: CactusCompletionParams(maxTokens: 200),
      );
      hintText = result.text.trim();
    } catch (e) {
      hintText = 'Hint failed: $e';
    }
    notifyListeners();
  }

  void updateDraft(String text) {
    draftText = text;
    if (phase == StudentPhase.promptReceived && text.isNotEmpty) {
      phase = StudentPhase.answering;
    }
    notifyListeners();
  }

  Future<void> submitAnswer() async {
    final prompt = currentPrompt;
    final peer = teacherPeer;
    final id = identity;
    final c = client;
    if (prompt == null || peer == null || id == null || c == null) {
      _append('Cannot submit: missing prompt or teacher peer.');
      return;
    }
    if (draftText.trim().isEmpty) {
      _append('Nothing to submit.');
      return;
    }
    phase = StudentPhase.submitting;
    notifyListeners();

    final resp = StudentResponse(
      lessonId: prompt.lessonId,
      stepId: prompt.stepId,
      studentFingerprint: id.fingerprint,
      studentAlias: id.alias,
      text: draftText.trim(),
      audioWasUsed: audioUsed,
      submittedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final ok = await c.submitResponse(peer: peer, response: resp);
    if (ok) {
      _append('Submitted answer to ${peer.alias}.');
      phase = StudentPhase.submitted;
    } else {
      _append('Submit failed; try again.');
      phase = StudentPhase.answering;
    }
    notifyListeners();
  }

  Future<void> _handlePromptArrived(LessonPrompt prompt, LanPeer from) async {
    _append('Prompt step ${prompt.stepIndex + 1}/${prompt.totalSteps} from ${from.alias}: "${prompt.text}"');
    currentPrompt = prompt;
    teacherPeer = from;
    currentLessonId = prompt.lessonId;
    draftText = '';
    audioUsed = false;
    hintText = null;
    phase = StudentPhase.promptReceived;
    // Remember this teacher so we know who to send responses to.
    if (!(pairing?.isTrusted(from.fingerprint) ?? false)) {
      await pairing?.trust(from);
    }
    _discovered[from.fingerprint] = from;
    notifyListeners();
  }

  Future<void> _handleControlArrived(ClassroomControl ctrl, LanPeer from) async {
    _append('Control ${ctrl.action.name} from ${from.alias}.');
    switch (ctrl.action) {
      case ControlAction.startLesson:
        currentLessonId = ctrl.lessonId;
        teacherPeer = from;
        draftText = '';
        audioUsed = false;
        hintText = null;
        currentPrompt = null;
        phase = StudentPhase.idle;
        break;
      case ControlAction.endLesson:
      case ControlAction.clearStep:
        currentPrompt = null;
        draftText = '';
        audioUsed = false;
        hintText = null;
        phase = StudentPhase.idle;
        if (ctrl.action == ControlAction.endLesson) currentLessonId = null;
        break;
      case ControlAction.advanceStep:
        // The actual new prompt arrives via /classroom/v1/prompt; this is
        // informational only.
        break;
    }
    notifyListeners();
  }

  /// Manually add a teacher peer by IP, bypassing multicast (useful in the
  /// iOS Simulator, which can't cross multicast). Probes /info to grab the
  /// peer's real fingerprint/alias.
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
      await pairing?.trust(peer);
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

  @override
  void dispose() {
    multicast?.stop();
    server?.stop();
    super.dispose();
  }
}
