import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';

import 'completed_lesson_store.dart';

/// High-level state machine for the student app. Sequence:
///
/// bootingModel  → waitingForTeacher
///               → lessonStartedNoPrompt   (teacher said Start but no step yet)
///               → promptReceived          (a new step arrived)
///               → answering
///               → submitting
///               → submitted
///               → lessonEnded             (teacher said End)
enum StudentPhase {
  bootingModel,
  waitingForTeacher,
  lessonStartedNoPrompt,
  promptReceived,
  answering,
  submitting,
  submitted,
  lessonEnded,
}

/// One turn of the private practice tutor. Roles match Cactus chat messages.
class TutorMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final int tsMs;
  TutorMessage({required this.role, required this.content, required this.tsMs});
}

/// Student-side core: discover the teacher Mac, host a small HTTP server that
/// receives prompts/control, capture answers (text or voice), clean them up
/// with on-device Gemma, submit them, and offer a private practice tutor
/// scoped to the current step.
class IosCore extends ChangeNotifier {
  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  final LanPeerScanner lanScanner = const LanPeerScanner();
  LanAgentClient? client;
  LanAgentServer? server;
  LmBootstrap? lmBoot;
  SttBootstrap? sttBoot;
  MicRecorder? recorder;
  PickedModel? loadedModel;
  bool sttReady = false;
  bool isRecording = false;
  bool isScanningLan = false;
  Future<void>? _modelLoadFuture;
  Future<void>? _lanScanFuture;
  Timer? _classroomPollTimer;
  bool _classroomPollInFlight = false;
  int _lastClassroomEventSequence = 0;
  final Set<String> _seenPromptKeys = {};
  final Set<String> _seenControlKeys = {};

  final Map<String, LanPeer> _discovered = {};
  bool get isModelLoading => _modelLoadFuture != null;
  List<LanPeer> get discoveredPeers =>
      _discovered.values.toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  // --- classroom session state ---
  StudentPhase phase = StudentPhase.bootingModel;
  LessonPrompt? currentPrompt;
  LanPeer? teacherPeer;
  String draftText = '';
  bool audioUsed = false;
  String? hintText;
  String? currentLessonId;

  // --- tutor chat state (private practice, never sent to teacher) ---
  final List<TutorMessage> tutorHistory = [];
  String? _tutorScopedStepId;
  bool tutorBusy = false;

  // --- standalone tutor tab (private practice scoped to a subject, driven by
  // past completed lessons rather than the active step). Independent state so
  // it doesn't collide with the per-step tutor on the active-class tab.
  CompletedLessonStore? completedLessons;
  final Map<String, List<String>> _inFlightPrompts = {};
  final Map<String, String?> _inFlightSubjects = {};
  String? generalTutorSubject;
  final List<TutorMessage> generalTutorHistory = [];
  bool generalTutorBusy = false;

  /// Maximum estimated tokens (chars / 3.5) for system + history + new user
  /// turn when calling Gemma. e2b on iPhone runs with a 1024 ctx; we reserve
  /// 220 for the response and ~120 for the system prompt.
  static const int _tutorBudgetTokens = 600;
  static const Duration _classroomPollInterval = Duration(seconds: 1);

  final List<String> log = [];
  String status = 'booting';

  void _append(String line) {
    log.add('${DateTime.now().toIso8601String().substring(11, 19)}  $line');
    if (log.length > 300) log.removeAt(0);
    status = line;
    notifyListeners();
  }

  /// True once the student has explicitly entered their name in the app.
  /// While false the UI nags them with a name-entry card so the teacher sees
  /// a real name in the gradebook instead of `Student-iPhone`.
  bool get hasUserSetName => identity?.aliasIsUserChosen ?? false;

  Future<void> bootstrap() async {
    identity = await DeviceIdentity.loadOrCreate(
      defaultAlias: 'Student-${Platform.localHostname}',
    );
    pairing = await PairingStore.open();
    completedLessons = await CompletedLessonStore.open();
    client = LanAgentClient(identity: identity!, acceptsIntents: false);
    lmBoot = LmBootstrap(tier: DeviceTier.phone);
    sttBoot = SttBootstrap();
    recorder = MicRecorder();

    _append(
      'Identity ready: ${identity!.alias} / ${identity!.fingerprint.substring(0, 8)}',
    );

    multicast = MulticastService(
      identity: identity!,
      acceptsIntents: false,
      onPeer: (p) {
        final isNew = !_discovered.containsKey(p.fingerprint);
        _discovered[p.fingerprint] = p;
        if (p.deviceType == 'desktop' &&
            (teacherPeer == null ||
                teacherPeer!.fingerprint == p.fingerprint)) {
          teacherPeer = p;
        }
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
      onPrompt: _applyPromptArrived,
      onControl: _applyControlArrived,
      // In a classroom the student trusts whatever teacher reaches them first;
      // there's no separate approval UI on the phone.
      onPendingPair: (peer) async {
        _append('Auto-trusting incoming teacher ${peer.alias}.');
        return true;
      },
    );
    var coLocatedAgentDetected = false;
    try {
      await server!.start();
      _append('Student server listening on :${LanConst.port}');
    } catch (e) {
      _append('Server start failed: $e');
      // errno 48 (Address already in use) almost always means another agent on
      // the same host is already bound to LanConst.port — typically the
      // teacher Mac app when both are on the same machine. Kick off an
      // immediate LAN scan so we surface that peer without waiting for the
      // delayed startup scan.
      if (e is SocketException && e.osError?.errorCode == 48) {
        coLocatedAgentDetected = true;
      }
    }

    // Background warm-up: tutor model first (required to use the app at all),
    // STT second (only needed for voice answer dictation).
    unawaited(_warmUpModelAndStt());
    if (coLocatedAgentDetected) {
      unawaited(scanLanForPeers(reason: 'co-located'));
    } else {
      unawaited(_startFallbackLanScan());
    }
    _startClassroomEventPolling();
    notifyListeners();
  }

  Future<void> _warmUpModelAndStt() async {
    try {
      await loadModel();
    } catch (e) {
      _append('Auto-load model failed: $e');
    }
    if (phase == StudentPhase.bootingModel) {
      phase = StudentPhase.waitingForTeacher;
      notifyListeners();
    }
    if (!sttReady) {
      try {
        await loadStt();
      } catch (e) {
        _append('Auto-load STT failed: $e');
      }
    }
  }

  Future<void> _startFallbackLanScan() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (_discovered.values.any((p) => p.deviceType == 'desktop')) return;
    await scanLanForPeers(reason: 'startup');
  }

  Future<void> scanLanForPeers({String reason = 'manual'}) async {
    final pending = _lanScanFuture;
    if (pending != null) {
      if (reason == 'manual') {
        _append('LAN scan already running.');
      }
      return pending;
    }

    final future = _scanLanForPeers(reason: reason);
    _lanScanFuture = future;
    isScanningLan = true;
    notifyListeners();

    await future.whenComplete(() {
      if (identical(_lanScanFuture, future)) {
        _lanScanFuture = null;
        isScanningLan = false;
        notifyListeners();
      }
    });
  }

  Future<void> _scanLanForPeers({required String reason}) async {
    final knownIps = pairing?.all().map((peer) => peer.ip) ?? const <String>[];
    if (reason != 'startup') {
      _append('Scanning local network for Mac peers...');
    }

    final summary = await lanScanner.scanLocalSubnets(preferredIps: knownIps);
    final selfFingerprint = identity?.fingerprint;
    for (final peer in summary.peers) {
      if (selfFingerprint != null && peer.fingerprint == selfFingerprint) {
        continue;
      }
      final previous = _discovered[peer.fingerprint];
      final merged =
          previous?.copyWith(
            ip: peer.ip,
            acceptsIntents: peer.acceptsIntents,
            lastSeen: peer.lastSeen,
          ) ??
          peer;
      _discovered[peer.fingerprint] = merged;
      if (merged.deviceType == 'desktop' &&
          (teacherPeer == null ||
              teacherPeer!.fingerprint == merged.fingerprint)) {
        teacherPeer = merged;
      }
      if (previous == null) {
        _append('Discovered ${merged.alias} @ ${merged.ip} via LAN scan');
      }
    }

    if (summary.peers.isEmpty) {
      if (summary.permissionDeniedCount > 0) {
        _append(
          'LAN scan blocked. Allow Local Network access for voice_ios in iPhone Settings.',
        );
      } else if (reason != 'startup') {
        _append('LAN scan finished with no Mac peers.');
      }
    } else if (reason != 'startup') {
      _append('LAN scan finished with ${summary.peers.length} peer(s).');
    }

    notifyListeners();
  }

  Future<void> loadModel() async {
    final pending = _modelLoadFuture;
    if (pending != null) {
      _append('Model load already in progress.');
      return pending;
    }
    final boot = lmBoot;
    if (boot == null) return;
    final future = () async {
      try {
        final picked = await boot.ensureReady(onStatus: _append);
        loadedModel = picked;
        if (!sttReady && canReusePickedModelForStt(picked)) {
          sttBoot = SttBootstrap(lm: boot.lm, tier: DeviceTier.phone);
          sttReady = true;
          _append('Reusing loaded ${picked.slug} for STT.');
        }
        notifyListeners();
      } catch (e) {
        _append('Model load failed: $e');
      }
    }();
    _modelLoadFuture = future;
    notifyListeners();
    future.whenComplete(() {
      if (identical(_modelLoadFuture, future)) {
        _modelLoadFuture = null;
        notifyListeners();
      }
    });
    return future;
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

  Future<String?> stopRecordingAndTranscribe() => _stopAndTranscribe();

  Future<String?> _stopAndTranscribe() async {
    final r = recorder;
    final stt = sttBoot;
    if (r == null || stt == null) return null;
    String? path;
    try {
      path = await r.stop().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _append('Recorder stop timed out - resetting recorder.');
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
You are a hint helper running privately on a student's phone. The teacher cannot see what you say. The student is stuck on a classroom prompt. Give a single small nudge - a question, an analogy, or a recall of a related concept - that helps them think. Never give the answer outright. Keep it under two sentences.
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

  String _tutorSystemPrompt(LessonPrompt prompt) {
    final format = switch (prompt.expectedFormat) {
      ExpectedFormat.short => 'short answer',
      ExpectedFormat.multipleChoice => 'multiple choice',
      ExpectedFormat.free => 'free response',
    };
    final optionsLine = prompt.expectedFormat == ExpectedFormat.multipleChoice
        ? '\n  OPTIONS: ${prompt.options.join(" | ")}'
        : '';
    return '''
You are a private practice tutor running entirely on the student's phone. The teacher cannot see this conversation. The student is working on this prompt:

  PROMPT: ${prompt.text}
  FORMAT: $format$optionsLine

Your job is to help the student think their way to a good answer. Never write the final answer for them. Prefer leading questions, breaking down the prompt, recalling a related concept, suggesting an analogy, or asking what they've tried. If they ask "what is the answer", politely refuse and ask what they think. Keep replies under 3 sentences.
''';
  }

  /// Multi-turn tutor chat, strictly local. History is reset when a new step
  /// arrives; it is never persisted across app kills.
  Future<void> askTutor(String userText) async {
    final boot = lmBoot;
    final prompt = currentPrompt;
    final trimmed = userText.trim();
    if (boot == null || loadedModel == null || prompt == null) {
      _append('Tutor unavailable (model or prompt missing).');
      return;
    }
    if (trimmed.isEmpty || tutorBusy) return;

    // Scope: reset on new step.
    if (_tutorScopedStepId != prompt.stepId) {
      tutorHistory.clear();
      _tutorScopedStepId = prompt.stepId;
    }

    tutorHistory.add(
      TutorMessage(
        role: 'user',
        content: trimmed,
        tsMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    tutorBusy = true;
    notifyListeners();

    try {
      final system = _tutorSystemPrompt(prompt);
      final history = _truncatedHistoryForBudget(system);
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: system),
          for (final m in history)
            ChatMessage(role: m.role, content: m.content),
        ],
        params: CactusCompletionParams(maxTokens: 220),
      );
      final reply = result.text.trim();
      tutorHistory.add(
        TutorMessage(
          role: 'assistant',
          content: reply.isEmpty ? '(no reply — try again)' : reply,
          tsMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      tutorHistory.add(
        TutorMessage(
          role: 'assistant',
          content: 'Tutor failed: $e',
          tsMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } finally {
      tutorBusy = false;
      notifyListeners();
    }
  }

  /// Drop oldest user/assistant pairs until estimated tokens fit the budget.
  /// Estimate: chars / 3.5. Always keeps the most recent user turn.
  List<TutorMessage> _truncatedHistoryForBudget(String systemPrompt) {
    final messages = List<TutorMessage>.from(tutorHistory);
    int tokens(String s) => (s.length / 3.5).ceil();
    var total =
        tokens(systemPrompt) +
        messages.fold<int>(0, (a, m) => a + tokens(m.content));
    // Drop oldest pairs while over budget but always leave at least the
    // newest user message.
    while (total > _tutorBudgetTokens && messages.length > 1) {
      final dropped = messages.removeAt(0);
      total -= tokens(dropped.content);
      if (messages.isNotEmpty &&
          messages.first.role == 'assistant' &&
          total > _tutorBudgetTokens) {
        total -= tokens(messages.first.content);
        messages.removeAt(0);
      }
    }
    return messages;
  }

  void clearTutorHistory() {
    tutorHistory.clear();
    notifyListeners();
  }

  void _recordPromptForCompletion(LessonPrompt prompt) {
    final bucket = _inFlightPrompts.putIfAbsent(prompt.lessonId, () => []);
    if (bucket.isEmpty || bucket.last != prompt.text) {
      bucket.add(prompt.text);
    }
    _inFlightSubjects[prompt.lessonId] = prompt.subject;
  }

  Future<void> _finalizeCompletedLesson(String lessonId) async {
    final store = completedLessons;
    final prompts = _inFlightPrompts.remove(lessonId);
    final subject = _inFlightSubjects.remove(lessonId);
    if (store == null || prompts == null || prompts.isEmpty) return;
    await store.record(
      CompletedLesson(
        lessonId: lessonId,
        subject: subject,
        completedAtMs: DateTime.now().millisecondsSinceEpoch,
        stepPrompts: List<String>.from(prompts),
      ),
    );
    _append('Lesson saved to Tutor (${subject ?? 'general'}).');
  }

  /// Group all completed lessons by subject for the Tutor tab. Subjects with no
  /// `subject` field on the prompt are bucketed under the literal "General"
  /// label so the UI still has something to render.
  Map<String, List<CompletedLesson>> completedLessonsBySubject() {
    final store = completedLessons;
    if (store == null) return const {};
    final grouped = store.bySubject();
    final out = <String, List<CompletedLesson>>{};
    grouped.forEach((subject, lessons) {
      out[subject ?? 'General'] = lessons;
    });
    return out;
  }

  /// Open the standalone Tutor tab against [subject]. Clears any prior chat
  /// for this surface so each visit starts fresh, then notifies listeners so
  /// the screen can pick up the new scope.
  void startGeneralTutor(String subject) {
    generalTutorSubject = subject;
    generalTutorHistory.clear();
    notifyListeners();
  }

  void clearGeneralTutorHistory() {
    generalTutorHistory.clear();
    notifyListeners();
  }

  String _generalTutorSystemPrompt(
    String subject,
    List<CompletedLesson> lessons,
  ) {
    final recentPrompts = <String>[];
    for (final l in lessons) {
      for (final p in l.stepPrompts) {
        recentPrompts.add(p);
        if (recentPrompts.length >= 8) break;
      }
      if (recentPrompts.length >= 8) break;
    }
    final practicedLine = recentPrompts.isEmpty
        ? ''
        : '\n\nThe student has recently practiced these questions in $subject:\n${recentPrompts.map((p) => '- $p').join('\n')}';
    return '''
You are a private practice tutor running entirely on the student's phone. The teacher cannot see this conversation. The student wants to keep practicing $subject after finishing one or more classroom lessons on the topic.$practicedLine

Your job is to help the student deepen their understanding. Offer a fresh practice question, a quick recap, an analogy, or a leading question - whatever fits what they ask. Never lecture for more than three sentences at a time. If they ask for "the answer", refuse politely and ask what they think first. Keep replies concise.
''';
  }

  /// Like [askTutor] but scoped to a subject (the Tutor tab), not a specific
  /// step. Uses [generalTutorHistory] and grounds the system prompt in the
  /// recent prompts the student saw in that subject.
  Future<void> askGeneralTutor(String userText) async {
    final boot = lmBoot;
    final subject = generalTutorSubject;
    final trimmed = userText.trim();
    if (boot == null || loadedModel == null || subject == null) {
      _append('General tutor unavailable (model not loaded).');
      return;
    }
    if (trimmed.isEmpty || generalTutorBusy) return;

    generalTutorHistory.add(
      TutorMessage(
        role: 'user',
        content: trimmed,
        tsMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    generalTutorBusy = true;
    notifyListeners();

    try {
      final lessons = completedLessons?.bySubject()[subject == 'General'
              ? null
              : subject] ??
          const <CompletedLesson>[];
      final system = _generalTutorSystemPrompt(subject, lessons);
      final history = _truncatedGeneralHistoryForBudget(system);
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: system),
          for (final m in history)
            ChatMessage(role: m.role, content: m.content),
        ],
        params: CactusCompletionParams(maxTokens: 220),
      );
      final reply = result.text.trim();
      generalTutorHistory.add(
        TutorMessage(
          role: 'assistant',
          content: reply.isEmpty ? '(no reply — try again)' : reply,
          tsMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      generalTutorHistory.add(
        TutorMessage(
          role: 'assistant',
          content: 'Tutor failed: $e',
          tsMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } finally {
      generalTutorBusy = false;
      notifyListeners();
    }
  }

  List<TutorMessage> _truncatedGeneralHistoryForBudget(String systemPrompt) {
    final messages = List<TutorMessage>.from(generalTutorHistory);
    int tokens(String s) => (s.length / 3.5).ceil();
    var total = tokens(systemPrompt) +
        messages.fold<int>(0, (a, m) => a + tokens(m.content));
    while (total > _tutorBudgetTokens && messages.length > 1) {
      final dropped = messages.removeAt(0);
      total -= tokens(dropped.content);
      if (messages.isNotEmpty &&
          messages.first.role == 'assistant' &&
          total > _tutorBudgetTokens) {
        total -= tokens(messages.first.content);
        messages.removeAt(0);
      }
    }
    return messages;
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

  void _startClassroomEventPolling() {
    _classroomPollTimer ??= Timer.periodic(
      _classroomPollInterval,
      (_) => unawaited(_pollClassroomEvents()),
    );
  }

  LanPeer? _classroomPollPeer() {
    final current = teacherPeer;
    if (current != null && current.deviceType == 'desktop') return current;
    for (final peer in _discovered.values) {
      if (peer.deviceType == 'desktop') return peer;
    }
    return null;
  }

  Future<void> _pollClassroomEvents() async {
    if (_classroomPollInFlight) return;
    final peer = _classroomPollPeer();
    final c = client;
    if (peer == null || c == null) return;

    _classroomPollInFlight = true;
    try {
      final batch = await c.pollClassroomEvents(
        peer: peer,
        afterSequence: _lastClassroomEventSequence,
      );
      if (batch == null) return;
      if (batch.latestSequence < _lastClassroomEventSequence) {
        _lastClassroomEventSequence = 0;
        return;
      }

      final events = List<ClassroomEvent>.from(batch.events)
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      for (final event in events) {
        if (event.sequence <= _lastClassroomEventSequence) continue;
        _lastClassroomEventSequence = event.sequence;
        switch (event.kind) {
          case ClassroomEventKind.prompt:
            final prompt = event.prompt;
            if (prompt != null) {
              await _applyPromptArrived(prompt, peer);
            }
            break;
          case ClassroomEventKind.control:
            final control = event.control;
            if (control != null) {
              await _applyControlArrived(control, peer);
            }
            break;
        }
      }
    } finally {
      _classroomPollInFlight = false;
    }
  }

  Future<void> _applyPromptArrived(LessonPrompt prompt, LanPeer from) async {
    final key = _promptKey(prompt);
    final alreadyApplied = !_seenPromptKeys.add(key);
    if (alreadyApplied && _currentPromptKey() == key) return;
    await _handlePromptArrived(prompt, from);
  }

  String _promptKey(LessonPrompt prompt) =>
      '${prompt.lessonId}:${prompt.stepId}:${prompt.issuedAtMs}';

  String? _currentPromptKey() {
    final prompt = currentPrompt;
    return prompt == null ? null : _promptKey(prompt);
  }

  Future<void> _applyControlArrived(ClassroomControl ctrl, LanPeer from) async {
    final key =
        '${ctrl.lessonId}:${ctrl.action.name}:${ctrl.stepIndex ?? -1}:${ctrl.issuedAtMs}';
    if (!_seenControlKeys.add(key)) return;
    await _handleControlArrived(ctrl, from);
  }

  Future<void> _handlePromptArrived(LessonPrompt prompt, LanPeer from) async {
    _append(
      'Prompt step ${prompt.stepIndex + 1}/${prompt.totalSteps} from ${from.alias}: "${prompt.text}"',
    );
    // Reset tutor history on a new step (different stepId).
    if (_tutorScopedStepId != prompt.stepId) {
      tutorHistory.clear();
      _tutorScopedStepId = prompt.stepId;
    }
    currentPrompt = prompt;
    teacherPeer = from;
    currentLessonId = prompt.lessonId;
    _recordPromptForCompletion(prompt);
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

  Future<void> _handleControlArrived(
    ClassroomControl ctrl,
    LanPeer from,
  ) async {
    _append('Control ${ctrl.action.name} from ${from.alias}.');
    teacherPeer = from;
    if (!(pairing?.isTrusted(from.fingerprint) ?? false)) {
      await pairing?.trust(from);
    }
    _discovered[from.fingerprint] = from;
    switch (ctrl.action) {
      case ControlAction.startLesson:
        currentLessonId = ctrl.lessonId;
        draftText = '';
        audioUsed = false;
        hintText = null;
        currentPrompt = null;
        tutorHistory.clear();
        _tutorScopedStepId = null;
        phase = StudentPhase.lessonStartedNoPrompt;
        break;
      case ControlAction.endLesson:
        await _finalizeCompletedLesson(ctrl.lessonId);
        currentPrompt = null;
        draftText = '';
        audioUsed = false;
        hintText = null;
        tutorHistory.clear();
        _tutorScopedStepId = null;
        currentLessonId = null;
        phase = StudentPhase.lessonEnded;
        break;
      case ControlAction.clearStep:
        currentPrompt = null;
        draftText = '';
        audioUsed = false;
        hintText = null;
        tutorHistory.clear();
        _tutorScopedStepId = null;
        phase = currentLessonId == null
            ? StudentPhase.waitingForTeacher
            : StudentPhase.lessonStartedNoPrompt;
        break;
      case ControlAction.advanceStep:
        // The actual new prompt arrives via /classroom/v1/prompt; this is
        // informational only.
        break;
    }
    notifyListeners();
  }

  /// Persist the student's chosen display name. The new alias is broadcast on
  /// the next multicast announce (forced immediately) and sent in headers on
  /// the next response submission, so the teacher's roster + gradebook pick it
  /// up within a few seconds.
  Future<void> setStudentName(String name) async {
    final id = identity;
    if (id == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == id.alias) return;
    await id.setAlias(trimmed, userChosen: true);
    multicast?.announce();
    _append('Name set to "$trimmed".');
    notifyListeners();
  }

  /// Manually add a teacher/Mac peer by IP, bypassing multicast (useful in the
  /// iOS Simulator, which cannot cross multicast). Probes /info to grab the
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
      final deviceType = (json['deviceType'] as String?) ?? 'desktop';
      final peer = LanPeer(
        alias: (json['alias'] as String?) ?? 'Mac@$ip',
        fingerprint: (json['fingerprint'] as String?) ?? 'manual-$ip',
        ip: ip,
        port: (json['port'] as num?)?.toInt() ?? LanConst.port,
        deviceType: deviceType,
        acceptsIntents:
            (json['acceptsIntents'] as bool?) ??
            LanPeer.defaultAcceptsIntentsForDeviceType(deviceType),
        lastSeen: DateTime.now(),
      );
      _discovered[peer.fingerprint] = peer;
      if (peer.deviceType == 'desktop') {
        teacherPeer = peer;
      }
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
    _classroomPollTimer?.cancel();
    multicast?.stop();
    server?.stop();
    super.dispose();
  }
}
