import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:automation_core/automation_core.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'agent_settings.dart';
import 'automation_dispatcher.dart';
import 'intent_handling.dart';
import 'lesson_store.dart';
import 'pairing_policy.dart';
import 'roster_store.dart';
import 'session_store.dart';
import 'teacher_dispatcher.dart';

enum TeacherChatMode { author, automation }

enum StudentSessionState { connected, answering, answered, disconnected }

/// Live-roster view of one student. The persisted record of their answers
/// and grades lives separately on the active [SessionRecord].
class StudentSlot {
  final LanPeer peer;
  StudentSessionState state;
  StudentResponse? lastResponse;

  StudentSlot({
    required this.peer,
    this.state = StudentSessionState.connected,
    this.lastResponse,
  });
}

class TeacherChatTurn {
  final String userText;
  final String replyText;
  final List<ToolCallTrace> trace;

  TeacherChatTurn({
    required this.userText,
    required this.replyText,
    required this.trace,
  });
}

class AgentCore extends ChangeNotifier implements TeacherToolBridge {
  AgentCore({AgentSettingsStore? settingsStore})
    : _settingsStore = settingsStore ?? AgentSettingsStore();

  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  LanAgentServer? server;
  LanAgentClient? client;
  AutomationService? automation;
  AutomationDispatcher? automationDispatcher;
  TeacherDispatcher? teacherDispatcher;
  LmBootstrap? lmBoot;
  SttBootstrap? sttBoot;
  MicRecorder? recorder;
  PickedModel? loadedModel;
  final AgentSettingsStore _settingsStore;
  InputAutomationStatus inputAutomationStatus =
      const InputAutomationStatus.uninitialized();
  bool autoTrustPhoneSenders = false;
  bool sttReady = false;
  bool isRecording = false;
  Future<void>? _modelLoadFuture;
  ReactLoop? _react;
  LessonStore? lessonStore;
  SessionStore? sessionStore;
  RosterStore? rosterStore;

  final Map<String, LanPeer> _discovered = {};
  List<LanPeer> get discoveredPeers =>
      _discovered.values.toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  List<LanPeer> get pairedPeers => pairing?.all() ?? const [];

  // --- classroom session state ---
  Lesson? currentLesson;
  List<Lesson> savedLessons = const [];
  int currentStepIndex = -1; // -1 = not started
  bool lessonRunning = false;
  final Map<String, StudentSlot> roster = {}; // fingerprint -> slot
  final List<ClassroomEvent> _classroomOutbox = [];
  int _classroomEventSequence = 0;
  static const int _maxClassroomOutboxEvents = 200;

  /// The persisted record for the current run. Null when no lesson is active.
  /// Mutated in place (with debounced save) as responses come in.
  SessionRecord? currentSession;

  /// Most-recent-first list of past session records loaded from disk.
  List<SessionRecord> savedSessions = const [];

  Timer? _saveDebounce;
  Timer? _stalePeerTimer;
  Future<void> _gradeQueue = Future<void>.value();
  bool gradingBusy = false;

  static const Duration _staleAfter = Duration(seconds: 15);

  // --- teacher chat state ---
  TeacherChatMode chatMode = TeacherChatMode.author;
  final List<TeacherChatTurn> chatHistory = [];
  bool chatBusy = false;

  /// True while the teacher's "Import from file" flow is reading a PDF/image
  /// and waiting on the lesson-draft LLM call. The authoring pane uses this
  /// to swap the import button for a spinner.
  bool importingFile = false;
  String? importStatus;
  String? lastImportError;

  /// Non-loopback IPv4 addresses, surfaced in the UI so the teacher can punch
  /// one into the Simulator's "Add manual peer" field.
  List<String> localIps = const [];
  bool get isModelLoading => _modelLoadFuture != null;

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
    identity = await DeviceIdentity.loadOrCreate(defaultAlias: 'Teacher-Mac');
    pairing = await PairingStore.open();
    lessonStore = await LessonStore.open();
    sessionStore = await SessionStore.open();
    rosterStore = await RosterStore.open();
    await refreshSavedLessons(loadMostRecent: true);
    await refreshSavedSessions();
    try {
      autoTrustPhoneSenders = await _settingsStore.loadAutoTrustPhoneSenders();
    } catch (e) {
      _append('Failed to load agent settings: $e');
      autoTrustPhoneSenders = false;
    }
    automation = AutomationService(
      onStatusUpdate: _append,
      onScreenshotTaken: () => _append('screenshot ready'),
    );
    automationDispatcher = AutomationDispatcher(automation!);
    teacherDispatcher = TeacherDispatcher(
      automation: automationDispatcher!,
      bridge: this,
    );
    lmBoot = LmBootstrap(tier: DeviceTier.desktop);
    sttBoot = SttBootstrap();
    recorder = MicRecorder();
    client = LanAgentClient(identity: identity!, acceptsIntents: true);

    server = LanAgentServer(
      identity: identity!,
      pairing: pairing!,
      onIntent: _handleIntent,
      onResponse: _handleStudentResponse,
      onClassroomEvents: _handleClassroomEventsPoll,
      onPendingPair: (p) async {
        if (autoTrustPhoneSenders && shouldAutoTrustIncomingPeer(p)) {
          _append(
            'Auto-trusting ${p.alias} @ ${p.ip} (${p.fingerprint.substring(0, 8)})',
          );
          return true;
        }
        _append(
          'Pair request from ${p.alias} @ ${p.ip} (${p.fingerprint.substring(0, 8)})',
        );
        pairRequests.add(p);
        return onPendingPair(p);
      },
    );
    await server!.start();
    _append('Server listening on :${LanConst.port}');

    multicast = MulticastService(
      identity: identity!,
      acceptsIntents: true,
      onPeer: (peer) {
        _discovered[peer.fingerprint] = peer;

        // Filter to phones/mobile devices for the classroom roster.
        if (peer.deviceType == 'mobile') {
          final isNew = !roster.containsKey(peer.fingerprint);
          final existing = roster[peer.fingerprint];
          final aliasChanged = existing != null && existing.peer.alias != peer.alias;
          roster[peer.fingerprint] = StudentSlot(
            peer: peer,
            state:
                existing?.state == StudentSessionState.answered &&
                    _stepIdForCurrent() == (existing?.lastResponse?.stepId)
                ? StudentSessionState.answered
                : (existing?.state == StudentSessionState.disconnected
                      ? StudentSessionState.connected
                      : (existing?.state ?? StudentSessionState.connected)),
            lastResponse: existing?.lastResponse,
          );
          if (isNew) {
            _append('Student joined: ${peer.alias} @ ${peer.ip}');
          } else if (aliasChanged) {
            _append('Student renamed: ${existing.peer.alias} → ${peer.alias}');
          }
          if (aliasChanged) {
            _syncSessionStudentDisplayName(peer.fingerprint, peer.alias);
          }
        }
        notifyListeners();
      },
    );
    try {
      await multicast!.start();
      _append('Multicast discovery started');
    } catch (e) {
      _append('Multicast failed: $e (unicast still works)');
    }

    _stalePeerTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _reapStalePeers(),
    );

    unawaited(refreshLocalIps());
    await initializeAutomationReadiness();
    unawaited(_warmUpModelAndStt());
    notifyListeners();
  }

  Future<void> _warmUpModelAndStt() async {
    try {
      await loadModel();
    } catch (e) {
      _append('Auto-load model failed: $e');
    }
    if (!sttReady) {
      try {
        await loadStt();
      } catch (e) {
        _append('Auto-load STT failed: $e');
      }
    }
  }

  Future<void> setAutoTrustPhoneSendersEnabled(bool enabled) async {
    final previous = autoTrustPhoneSenders;
    autoTrustPhoneSenders = enabled;
    notifyListeners();
    try {
      await _settingsStore.setAutoTrustPhoneSenders(enabled);
      _append(
        enabled
            ? 'Auto-trust for iPhone senders enabled.'
            : 'Auto-trust for iPhone senders disabled.',
      );
    } catch (e) {
      autoTrustPhoneSenders = previous;
      _append('Failed to save auto-trust setting: $e');
      notifyListeners();
    }
  }

  Future<void> initializeAutomationReadiness() async {
    final service = automation;
    if (service == null) return;
    inputAutomationStatus = await service.initializeInputAutomation();
    notifyListeners();
  }

  Future<void> refreshAutomationReadiness() async {
    final service = automation;
    if (service == null) return;
    inputAutomationStatus = await service.refreshInputAutomationReadiness();
    notifyListeners();
  }

  Future<void> openAccessibilitySettings() async {
    final service = automation;
    if (service == null) return;
    try {
      await service.openAccessibilitySettings();
    } catch (e) {
      _append('Failed to open Accessibility settings: $e');
    }
  }

  Future<void> restartForAccessibility() async {
    final service = automation;
    if (service == null) return;
    try {
      _append('Restarting agent_mac to refresh Accessibility access...');
      await service.relaunchApplication();
    } catch (e) {
      _append('Failed to restart agent_mac: $e');
    }
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
        _react = ReactLoop(lm: boot.lm);
        if (!sttReady && canReusePickedModelForStt(picked)) {
          sttBoot = SttBootstrap(lm: boot.lm, tier: DeviceTier.desktop);
          sttReady = true;
          _append('Reusing loaded ${picked.slug} for STT.');
        }
        _append('Model load: success (${picked.slug})');
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

  Future<bool> ensureMicrophonePermission() async {
    final r = recorder;
    if (r == null) return false;
    return r.hasPermission();
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
      _append('Recorder stop timed out - resetting recorder.');
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

  // ---------------- Phone intent automation ----------------

  static String _buildIntentSystemPrompt() {
    final now = DateTime.now();
    final iso =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final weekday = weekdays[now.weekday - 1];
    return '''
You are a macOS automation agent. You receive high-level natural-language intents (often transcribed from a phone PTT button) and satisfy them by calling the provided tools on the user's Mac.

Today is $iso ($weekday). Use this to resolve relative dates the user mentions ("today", "tomorrow", "Thursday", "next Monday", "in two weeks") into absolute YYYY-MM-DD values. When the user says a weekday, pick the next occurrence of that weekday strictly after today.

Routing rules - pick the most direct tool, do not improvise:
- For ANY scheduling, reminder, appointment, prescription pickup, or "add to calendar" request -> call `createCalendarEvent` ONCE with a clean title and a resolved ISO date. Do NOT open Calendar.app via Spotlight; do NOT click. Examples that match this rule: "Prescribed some medicine for pickup on Thursday", "Add dentist appointment next Tuesday at 2pm", "Remind me to call mom on Friday".
- For everything else, prefer keyboard shortcuts (`pressKeys`) over mouse/vision. Use cmd+space for Spotlight, cmd+t for new tab, etc.
- Keys for pressKeys must be UniversalKey enum names (e.g., "leftCommand", "space", "t", "returnKey", "leftShift").
- Break multi-step intents into a sequence of tool calls.
- Do not finish by restating the user's imperative as plain text. If the user asked you to perform a macOS action, you must emit tool calls unless the task is already complete or impossible.
- When the intent is fully done, respond with a short natural-language summary and NO tool calls.
- If a tool returns {"success": false}, adapt: try an alternative approach or abort with a clear explanation.

Calendar tool tips:
- Default startTime is 09:00 and durationMinutes is 30 - only override if the user gave a time.
- Set `notes` to the original user transcript so they can find context later.
- Title should be short and imperative ("Pick up prescription", "Doctor appointment"), not a full sentence.
''';
  }

  Future<IntentResponse> _handleIntent(IntentRequest req, LanPeer from) async {
    _append('Intent from ${from.alias}: "${req.text}"');

    final d = automationDispatcher;
    if (d == null) {
      const note = 'Mac agent not ready: automation not initialized yet.';
      _append(note);
      return IntentResponse(
        correlationId: req.correlationId,
        success: false,
        text: note,
        errorCode: 'not_ready',
      );
    }

    final fastPath = matchIntentFastPath(req.text);
    if (fastPath != null) {
      _append('Fast-path matched: ${fastPath.name}');
      final stopwatch = Stopwatch()..start();
      Map<String, dynamic> result;
      try {
        result = await d.dispatch(fastPath.toolName, fastPath.toolArguments);
      } catch (e) {
        result = {'success': false, 'message': 'dispatch threw: $e'};
      }
      stopwatch.stop();
      final trace = [
        ToolCallTrace(
          toolName: fastPath.toolName,
          args: fastPath.toolArguments,
          result: result,
          ms: stopwatch.elapsedMilliseconds,
        ),
      ];
      final success = result['success'] == true;
      final message = (result['message'] ?? '').toString();
      _append(
        success
            ? 'Fast-path completed: ${fastPath.name}'
            : 'Fast-path failed: $message',
      );
      return IntentResponse(
        correlationId: req.correlationId,
        success: success,
        text: success
            ? fastPath.successText
            : (message.isEmpty ? 'Fast-path failed.' : message),
        trace: trace,
      );
    }

    final react = _react;
    if (loadedModel == null || react == null) {
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
        ChatMessage(role: 'system', content: _buildIntentSystemPrompt()),
        ChatMessage(role: 'user', content: req.text),
      ],
      tools: d.buildTools(),
      dispatch: d.dispatch,
      onStatus: _append,
    );

    return buildIntentResponseFromRun(
      request: req,
      run: run,
      modelSlug: loadedModel!.slug,
      isFallback: loadedModel!.isFallback,
      onLog: _append,
    );
  }

  /// Run an intent locally (no LocalSend hop) - useful for testing on Mac
  /// without a paired phone.
  Future<IntentResponse> runLocal(String text) async {
    final id = identity;
    final req = IntentRequest.create(
      text: text,
      sourceDevice: id?.alias ?? 'local',
    );
    return _handleIntent(
      req,
      LanPeer(
        alias: id?.alias ?? 'local',
        fingerprint: id?.fingerprint ?? 'local',
        ip: '127.0.0.1',
        port: LanConst.port,
        deviceType: 'desktop',
        acceptsIntents: true,
        lastSeen: DateTime.now(),
      ),
    );
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

  // ---------------- Teacher chat ----------------

  String _systemPromptFor(TeacherChatMode mode) {
    final now = DateTime.now();
    final iso =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final weekday = weekdays[now.weekday - 1];

    final rosterSize = roster.length;
    final stepInfo = currentLesson == null
        ? 'No lesson is loaded.'
        : 'A lesson titled "${currentLesson!.title}" with ${currentLesson!.steps.length} steps is loaded. Current step index: $currentStepIndex (-1 means not yet started).';

    switch (mode) {
      case TeacherChatMode.author:
        return '''
You are an AI co-teacher running on a teacher's Mac. You help the teacher design and facilitate interactive classroom lessons that are pushed to student phones over LAN. Today is $iso ($weekday). There are $rosterSize student phone(s) currently connected. $stepInfo

Tool playbook:
- To draft a lesson from a topic, call `generate_lesson(topic, grade, numSteps)`. After it returns, write a one-sentence acknowledgement so the teacher can review the lesson before pushing.
- To start class, call `push_prompt(stepIndex=0)`.
- To move on, call `next_step()`.
- To wrap up, call `end_lesson()`.
- To analyze answers, call `summarize_responses()` and then write the summary as your final message (no further tool calls).
- The macOS automation tools (Spotlight, keyboard, calendar) are also available - use them only when the teacher explicitly asks for a desktop action like opening an app or adding a calendar entry.
- When the user's request is satisfied, reply with a short natural-language sentence and NO tool calls.
''';
      case TeacherChatMode.automation:
        return '''
You are a macOS automation agent. Today is $iso ($weekday). Use this to resolve relative dates the user mentions into absolute YYYY-MM-DD values. Pick the most direct tool, do not improvise:
- For any scheduling / reminder / calendar request -> call `createCalendarEvent` ONCE with a clean title and resolved date.
- For everything else, prefer `pressKeys` (UniversalKey enum names) over mouse/vision. Use cmd+space for Spotlight, cmd+t for new tab, etc.
- Break multi-step intents into a sequence of tool calls.
- The classroom tools (generate_lesson, push_prompt, ...) are also registered but should only be used if the teacher explicitly references a lesson.
- When the intent is fully done, reply with a short summary and NO tool calls.
''';
    }
  }

  Future<void> sendTeacherChat(String text) async {
    final react = _react;
    final disp = teacherDispatcher;
    if (loadedModel == null || react == null || disp == null) {
      _append('Cannot run chat: model not loaded.');
      return;
    }
    if (text.trim().isEmpty) return;
    chatBusy = true;
    notifyListeners();
    try {
      final run = await react.run(
        messages: [
          ChatMessage(role: 'system', content: _systemPromptFor(chatMode)),
          ChatMessage(role: 'user', content: text),
        ],
        tools: disp.buildTools(),
        dispatch: disp.dispatch,
        onStatus: _append,
      );
      chatHistory.add(
        TeacherChatTurn(
          userText: text,
          replyText: run.finalText,
          trace: run.trace,
        ),
      );
    } finally {
      chatBusy = false;
      notifyListeners();
    }
  }

  void setChatMode(TeacherChatMode mode) {
    chatMode = mode;
    notifyListeners();
  }

  // ---------------- Lesson lifecycle ----------------

  void replaceLesson(Lesson lesson) {
    if (lessonRunning) {
      // Persist the in-flight session before clobbering it with a new lesson.
      unawaited(endLessonUi());
    }
    currentLesson = lesson;
    currentStepIndex = -1;
    lessonRunning = false;
    currentSession = null;
    for (final slot in roster.values) {
      slot.state = StudentSessionState.connected;
      slot.lastResponse = null;
    }
    savedLessons = [
      lesson,
      ...savedLessons.where((saved) => saved.id != lesson.id),
    ];
    unawaited(
      (lessonStore?.save(lesson) ?? Future<void>.value()).then(
        (_) => refreshSavedLessons(),
        onError: (Object e) => _append('Failed to save lesson: $e'),
      ),
    );
    _append('Loaded lesson "${lesson.title}" (${lesson.steps.length} steps).');
    notifyListeners();
  }

  Future<void> refreshSavedLessons({bool loadMostRecent = false}) async {
    final store = lessonStore;
    if (store == null) return;
    final lessons = await store.list();
    savedLessons = lessons;
    if (loadMostRecent && currentLesson == null && lessons.isNotEmpty) {
      currentLesson = lessons.first;
      currentStepIndex = -1;
      lessonRunning = false;
      currentSession = null;
      _append('Restored lesson "${currentLesson!.title}".');
    }
    notifyListeners();
  }

  Future<void> loadSavedLesson(Lesson lesson) async {
    if (lessonRunning && currentLesson?.id != lesson.id) {
      await endLessonUi();
    }
    currentLesson = lesson;
    currentStepIndex = -1;
    lessonRunning = false;
    currentSession = null;
    for (final slot in roster.values) {
      slot.state = StudentSessionState.connected;
      slot.lastResponse = null;
    }
    _append('Loaded saved lesson "${lesson.title}".');
    notifyListeners();
  }

  Future<void> updateLessonInPlace(Lesson updated) async {
    final store = lessonStore;
    if (store == null) return;
    await store.save(updated);
    if (currentLesson?.id == updated.id) {
      currentLesson = updated;
    }
    savedLessons = [
      updated,
      ...savedLessons.where((saved) => saved.id != updated.id),
    ];
    notifyListeners();
  }

  Future<void> deleteSavedLesson(String id) async {
    if (lessonRunning && currentLesson?.id == id) {
      await endLessonUi();
    }
    await lessonStore?.delete(id);
    savedLessons = savedLessons.where((lesson) => lesson.id != id).toList();
    if (currentLesson?.id == id) {
      currentLesson = null;
      currentStepIndex = -1;
      lessonRunning = false;
      currentSession = null;
    }
    _append('Deleted saved lesson.');
    notifyListeners();
  }

  Future<void> startLesson() async {
    final lesson = currentLesson;
    if (lesson == null || lesson.steps.isEmpty) {
      _append('No lesson to start.');
      return;
    }
    lessonRunning = true;
    currentStepIndex = -1;
    _resetClassroomOutbox();
    _beginSessionFor(lesson);
    final ctrl = ClassroomControl.now(
      lessonId: lesson.id,
      action: ControlAction.startLesson,
    );
    await _broadcastControl(ctrl);
    await pushStep(0);
  }

  void _beginSessionFor(Lesson lesson) {
    final mobilePeers = roster.values.where(
      (slot) => slot.peer.deviceType == 'mobile',
    );
    final students = mobilePeers
        .map(
          (slot) => SessionStudent(
            fingerprint: slot.peer.fingerprint,
            alias: slot.peer.alias,
            displayName:
                rosterStore?.resolveName(
                  slot.peer.fingerprint,
                  slot.peer.alias,
                ) ??
                slot.peer.alias,
          ),
        )
        .toList();
    currentSession = SessionRecord.start(lesson: lesson, students: students);
    _schedulePersist();
    _append('Session started: ${currentSession!.id.substring(0, 8)}');
  }

  Future<void> pushStep(int index) async {
    final lesson = currentLesson;
    final c = client;
    if (lesson == null || c == null) return;
    if (index < 0 || index >= lesson.steps.length) {
      _append('pushStep: index $index out of range.');
      return;
    }
    currentStepIndex = index;
    final step = lesson.steps[index];
    final prompt = LessonPrompt.fromStep(
      lessonId: lesson.id,
      step: step,
      totalSteps: lesson.steps.length,
      subject: lesson.subject,
    );
    _queueClassroomPrompt(prompt);
    for (final slot in roster.values) {
      slot.state = StudentSessionState.answering;
      slot.lastResponse = null;
    }
    notifyListeners();

    final peers = roster.values.map((s) => s.peer).toList();
    if (peers.isEmpty) {
      _append('No students connected - prompt staged but not pushed.');
      return;
    }
    for (final peer in peers) {
      final ok = await c.pushPrompt(peer: peer, prompt: prompt);
      if (!ok) {
        _append('Prompt push to ${peer.alias} failed; queued for pull sync.');
      }
    }
    _append(
      'Pushed step ${index + 1}/${lesson.steps.length} to ${peers.length} student(s).',
    );
    notifyListeners();
  }

  Future<void> nextStepUi() async {
    final lesson = currentLesson;
    if (lesson == null) return;
    if (currentStepIndex + 1 >= lesson.steps.length) {
      _append('Already on last step - call End Lesson when done.');
      return;
    }
    await pushStep(currentStepIndex + 1);
  }

  Future<void> endLessonUi() async {
    final lesson = currentLesson;
    if (lesson == null) return;
    final wasRunning = lessonRunning;
    lessonRunning = false;
    currentStepIndex = -1;
    final session = currentSession;
    if (session != null && wasRunning) {
      currentSession = session.copyWith(
        endedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistSessionImmediate();
      await refreshSavedSessions();
    }
    currentSession = null;
    await _broadcastControl(
      ClassroomControl.now(
        lessonId: lesson.id,
        action: ControlAction.endLesson,
      ),
    );
    for (final slot in roster.values) {
      slot.state = StudentSessionState.connected;
    }
    _append('Lesson ended.');
    notifyListeners();
  }

  Future<void> _broadcastControl(ClassroomControl ctrl) async {
    final c = client;
    if (c == null) return;
    _queueClassroomControl(ctrl);
    final peers = roster.values.map((s) => s.peer).toList();
    for (final peer in peers) {
      final ok = await c.sendControl(peer: peer, control: ctrl);
      if (!ok) {
        _append('Control push to ${peer.alias} failed; queued for pull sync.');
      }
    }
  }

  void _resetClassroomOutbox() {
    _classroomOutbox.clear();
    _classroomEventSequence = 0;
  }

  void _queueClassroomPrompt(LessonPrompt prompt) {
    _appendClassroomEvent(
      ClassroomEvent.prompt(
        sequence: ++_classroomEventSequence,
        prompt: prompt,
      ),
    );
  }

  void _queueClassroomControl(ClassroomControl control) {
    _appendClassroomEvent(
      ClassroomEvent.control(
        sequence: ++_classroomEventSequence,
        control: control,
      ),
    );
  }

  void _appendClassroomEvent(ClassroomEvent event) {
    _classroomOutbox.add(event);
    if (_classroomOutbox.length > _maxClassroomOutboxEvents) {
      _classroomOutbox.removeRange(
        0,
        _classroomOutbox.length - _maxClassroomOutboxEvents,
      );
    }
  }

  Future<ClassroomEventBatch> _handleClassroomEventsPoll(
    LanPeer from,
    int afterSequence,
  ) async {
    final events = _classroomOutbox
        .where((event) => event.sequence > afterSequence)
        .toList(growable: false);
    return ClassroomEventBatch(
      latestSequence: _classroomEventSequence,
      events: events,
    );
  }

  String? _stepIdForCurrent() {
    final lesson = currentLesson;
    if (lesson == null) return null;
    if (currentStepIndex < 0 || currentStepIndex >= lesson.steps.length) {
      return null;
    }
    return lesson.steps[currentStepIndex].id;
  }

  Future<void> _handleStudentResponse(
    StudentResponse resp,
    LanPeer from,
  ) async {
    // 1) Live UI: update the StudentSlot.
    final slot = roster[resp.studentFingerprint];
    if (slot != null) {
      slot.state = StudentSessionState.answered;
      slot.lastResponse = resp;
    } else {
      roster[resp.studentFingerprint] = StudentSlot(
        peer: from,
        state: StudentSessionState.answered,
        lastResponse: resp,
      );
    }

    // 2) Persisted session: insert or replace the GradedResponse. We don't
    //    auto-create a session here — if a teacher hasn't started a lesson
    //    yet, an unsolicited response from an old prompt is dropped from the
    //    gradebook (but still shown in the live pane).
    final session = currentSession;
    if (session != null) {
      final displayName =
          rosterStore?.resolveName(
            resp.studentFingerprint,
            resp.studentAlias,
          ) ??
          resp.studentAlias;
      final students = [...session.students];
      final existingIdx = students.indexWhere(
        (s) => s.fingerprint == resp.studentFingerprint,
      );
      if (existingIdx < 0) {
        students.add(
          SessionStudent(
            fingerprint: resp.studentFingerprint,
            alias: resp.studentAlias,
            displayName: displayName,
          ),
        );
      } else if (students[existingIdx].displayName != displayName) {
        // Student renamed themselves (or teacher just set an override) - keep
        // the gradebook in sync. Original [alias] stays frozen for grading
        // integrity.
        students[existingIdx] = students[existingIdx].copyWith(
          displayName: displayName,
        );
      }
      final responses = [...session.responses];
      final priorIdx = responses.indexWhere(
        (r) =>
            r.studentFingerprint == resp.studentFingerprint &&
            r.stepId == resp.stepId,
      );
      final next = GradedResponse(
        studentFingerprint: resp.studentFingerprint,
        studentAlias: resp.studentAlias,
        stepId: resp.stepId,
        text: resp.text,
        audioWasUsed: resp.audioWasUsed,
        submittedAtMs: resp.submittedAtMs,
        // Resubmission clears any prior grade since the answer text changed.
      );
      if (priorIdx >= 0) {
        responses[priorIdx] = next;
      } else {
        responses.add(next);
      }
      currentSession = session.copyWith(
        students: students,
        responses: responses,
      );
      _schedulePersist();
    }

    _append('Response from ${resp.studentAlias} (${resp.text.length} chars).');
    notifyListeners();
  }

  // ---------------- Persistence + session management ----------------

  Future<void> refreshSavedSessions() async {
    final store = sessionStore;
    if (store == null) return;
    savedSessions = await store.list();
    notifyListeners();
  }

  Future<SessionRecord?> loadSavedSession(String id) async {
    final store = sessionStore;
    if (store == null) return null;
    return store.load(id);
  }

  Future<void> deleteSavedSession(String id) async {
    await sessionStore?.delete(id);
    savedSessions = savedSessions.where((s) => s.id != id).toList();
    notifyListeners();
  }

  void _schedulePersist() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistSessionImmediate());
    });
  }

  Future<void> _persistSessionImmediate() async {
    final store = sessionStore;
    final session = currentSession;
    if (store == null || session == null) return;
    try {
      await store.save(session);
    } catch (e) {
      _append('Session save failed: $e');
    }
  }

  void _reapStalePeers() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    var changed = false;
    for (final slot in roster.values) {
      if (slot.state == StudentSessionState.disconnected) continue;
      if (slot.peer.lastSeen.isBefore(cutoff)) {
        slot.state = StudentSessionState.disconnected;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ---------------- Grading ----------------

  /// Apply a teacher (or accepted-AI) grade to a response. Persists immediately.
  Future<void> setGrade({
    required String sessionId,
    required String studentFingerprint,
    required String stepId,
    Grade? grade,
    GradeSource source = GradeSource.teacher,
    String? comment,
  }) async {
    final isCurrent = currentSession?.id == sessionId;
    final session = isCurrent
        ? currentSession!
        : await loadSavedSession(sessionId);
    if (session == null) {
      _append('setGrade: session $sessionId not found.');
      return;
    }
    final responses = [...session.responses];
    final idx = responses.indexWhere(
      (r) => r.studentFingerprint == studentFingerprint && r.stepId == stepId,
    );
    if (idx < 0) {
      _append('setGrade: response not found.');
      return;
    }
    responses[idx] = responses[idx].copyWith(
      grade: grade,
      gradeSource: grade == null ? null : source,
      gradeComment: comment,
      gradedAtMs: grade == null ? null : DateTime.now().millisecondsSinceEpoch,
    );
    final updated = session.copyWith(responses: responses);
    await sessionStore?.save(updated);
    if (isCurrent) {
      currentSession = updated;
    }
    savedSessions = [updated, ...savedSessions.where((s) => s.id != sessionId)]
      ..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    notifyListeners();
  }

  /// Reflect a student's freshly-announced alias in the active session
  /// without waiting for their next answer submission. Manual roster
  /// overrides still take precedence (via [RosterStore.resolveName]).
  void _syncSessionStudentDisplayName(String fingerprint, String latestAlias) {
    final session = currentSession;
    if (session == null) return;
    final idx = session.students.indexWhere((s) => s.fingerprint == fingerprint);
    if (idx < 0) return;
    final resolved =
        rosterStore?.resolveName(fingerprint, latestAlias) ?? latestAlias;
    if (session.students[idx].displayName == resolved) return;
    final updated = [...session.students];
    updated[idx] = updated[idx].copyWith(displayName: resolved);
    currentSession = session.copyWith(students: updated);
    _schedulePersist();
  }

  Future<void> setStudentDisplayName(
    String fingerprint,
    String displayName,
  ) async {
    await rosterStore?.setDisplayName(fingerprint, displayName);
    final resolved =
        rosterStore?.displayName(fingerprint) ??
        roster[fingerprint]?.peer.alias ??
        fingerprint;
    final session = currentSession;
    if (session != null) {
      final updatedStudents = session.students
          .map(
            (s) => s.fingerprint == fingerprint
                ? s.copyWith(displayName: resolved)
                : s,
          )
          .toList();
      currentSession = session.copyWith(students: updatedStudents);
      _schedulePersist();
    }
    notifyListeners();
  }

  static const _gradingSystemPrompt = '''
You are an automated grader. Given the question, the expected answer key, and a student's submitted answer, classify the student's answer as one of: "correct", "partial", or "incorrect". Then write a one-sentence justification.

Output ONLY this JSON object, no prose, no fences:
{"grade": "correct"|"partial"|"incorrect", "explanation": "<one sentence>"}

Definitions:
- correct: addresses all key points, no major errors.
- partial: gets the main idea but misses a key point or has a minor factual error.
- incorrect: misses the main idea or contains a major factual error.
''';

  /// Compute a grade suggestion for [response] against [step]. Multiple-choice
  /// with a marked-correct option short-circuits without an LLM call. Free /
  /// short prompts call into Gemma with strict JSON output. Returns a draft
  /// the teacher confirms via [setGrade].
  Future<({Grade grade, String explanation})?> suggestGrade({
    required LessonStep step,
    required GradedResponse response,
  }) async {
    if (step.expectedFormat == ExpectedFormat.multipleChoice &&
        step.correctOptionIndex != null &&
        step.correctOptionIndex! >= 0 &&
        step.correctOptionIndex! < step.options.length) {
      final correct = step.options[step.correctOptionIndex!];
      final picked = response.text.trim();
      if (picked == correct) {
        return (
          grade: Grade.correct,
          explanation: 'Matches the correct option.',
        );
      }
      return (
        grade: Grade.incorrect,
        explanation: 'Picked "$picked"; expected "$correct".',
      );
    }
    final boot = lmBoot;
    if (boot == null || loadedModel == null) {
      return null;
    }
    final expected = (step.expectedAnswer ?? step.teacherNotes ?? '').trim();
    if (expected.isEmpty) {
      return null;
    }

    final completer = Completer<({Grade grade, String explanation})?>();
    _gradeQueue = _gradeQueue.then((_) async {
      gradingBusy = true;
      notifyListeners();
      try {
        final result = await boot.lm.generateCompletion(
          messages: [
            ChatMessage(role: 'system', content: _gradingSystemPrompt),
            ChatMessage(
              role: 'user',
              content:
                  'Question: ${step.prompt}\nExpected answer: $expected\nStudent answer: ${response.text}',
            ),
          ],
          params: CactusCompletionParams(maxTokens: 256),
        );
        final parsed = _parseGradeJson(result.text);
        completer.complete(parsed);
      } catch (e) {
        _append('suggestGrade failed: $e');
        completer.complete(null);
      } finally {
        gradingBusy = false;
        notifyListeners();
      }
    });
    return completer.future;
  }

  static ({Grade grade, String explanation})? _parseGradeJson(String src) {
    final obj = _extractFirstJsonObject(src);
    if (obj == null) return null;
    final gradeRaw = obj['grade'];
    final explanationRaw = obj['explanation'];
    final grade = gradeRaw is String ? gradeFromString(gradeRaw) : null;
    if (grade == null) return null;
    final explanation = explanationRaw is String && explanationRaw.isNotEmpty
        ? explanationRaw
        : 'No explanation provided.';
    return (grade: grade, explanation: explanation);
  }

  static Map<String, dynamic>? _extractFirstJsonObject(String src) {
    final start = src.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < src.length; i++) {
      final ch = src[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (ch == r'\') {
        escape = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          try {
            final decoded = jsonDecode(src.substring(start, i + 1));
            if (decoded is Map) return Map<String, dynamic>.from(decoded);
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  // ---------------- TeacherToolBridge ----------------

  static const _lessonDraftSystemPrompt = '''
You draft interactive classroom lessons. Output ONLY a single JSON object - no prose, no code fences. Schema:
{
  "title": string,
  "subject": string,
  "steps": [
    {
      "prompt": string,
      "teacherNotes": string,
      "expectedFormat": "free" | "short" | "multipleChoice",
      "options": string[],
      "expectedAnswer": string
    }
  ]
}
The prompt is the question the student sees. Keep each prompt under 200 characters and answerable in a few sentences. Use "free" by default, "short" for quick checks, and "multipleChoice" only when 2-5 useful options are included. Sequence prompts from concrete to more abstract.
Set "subject" to a broad school subject such as Mathematics, Science, English Language Arts, Social Studies, Computer Science, World Language, Arts, or Health.
For each step, include "expectedAnswer" — a brief reference answer (one or two sentences) so the AI grader has something to compare against later. For multipleChoice steps, "expectedAnswer" should be the correct option's exact text.
''';

  @override
  Future<Map<String, dynamic>> generateLesson({
    required String topic,
    required String grade,
    required int numSteps,
  }) async {
    final boot = lmBoot;
    if (boot == null || loadedModel == null) {
      return {'success': false, 'message': 'Model not loaded.'};
    }
    final n = numSteps.clamp(1, 8);
    _append('Drafting lesson on "$topic" ($grade, $n steps)...');
    try {
      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: _lessonDraftSystemPrompt),
          ChatMessage(
            role: 'user',
            content:
                'Draft a lesson with exactly $n steps on the topic "$topic" for $grade. Return JSON only.',
          ),
        ],
        params: CactusCompletionParams(maxTokens: 1024),
      );
      final lesson = LessonDraftParser.tryParse(
        modelOutput: result.text,
        fallbackTitle: '$topic ($grade)',
        topic: topic,
        grade: grade,
      );
      if (lesson == null) {
        return {
          'success': false,
          'message': 'Could not parse a lesson from the model output.',
        };
      }
      replaceLesson(lesson);
      return {
        'success': true,
        'title': lesson.title,
        'subject': lesson.subject,
        'numSteps': lesson.steps.length,
        'steps': lesson.steps.map((s) => s.prompt).toList(),
      };
    } catch (e) {
      return {'success': false, 'message': 'Draft failed: $e'};
    }
  }

  static const _importLessonSystemPrompt = '''
You convert source material (PDF text, worksheet scans, or images) into an interactive classroom lesson. Output ONLY a single JSON object - no prose, no code fences. Schema:
{
  "title": string,
  "subject": string,
  "topic": string,
  "gradeLevel": string,
  "steps": [
    {
      "prompt": string,
      "teacherNotes": string,
      "expectedFormat": "free" | "short" | "multipleChoice",
      "options": string[],
      "expectedAnswer": string
    }
  ]
}
Stay grounded in the source material — every step must check understanding of content that actually appears in the source. Do not invent facts that contradict it. Sequence prompts from concrete recall to higher-order reasoning. Keep each prompt under 200 characters and answerable in a few sentences. Default to "free" or "short"; use "multipleChoice" only when 2-5 useful options exist (then "expectedAnswer" should match the correct option exactly). For every step include "expectedAnswer" — a one-sentence reference answer derived from the source so the grader has something to compare against. Set "subject" to a broad school subject (Mathematics, Science, English Language Arts, Social Studies, Computer Science, World Language, Arts, Health).
''';

  /// Build a lesson from a teacher-supplied PDF or image. PDFs are
  /// text-extracted on-device via syncfusion_flutter_pdf and the text is fed
  /// to the same draft-lesson model used by [generateLesson]. Images are
  /// passed through to the multimodal channel of the model — if the loaded
  /// model doesn't have vision wired up, the model will fall back to using
  /// the filename / hint as a topic.
  Future<Map<String, dynamic>> importLessonFromFile({
    required String filePath,
    String? hint,
    String grade = 'general audience',
    int numSteps = 4,
  }) async {
    final boot = lmBoot;
    if (boot == null || loadedModel == null) {
      lastImportError = 'Model not loaded.';
      notifyListeners();
      return {'success': false, 'message': lastImportError};
    }
    if (importingFile) {
      return {'success': false, 'message': 'Import already in progress.'};
    }
    importingFile = true;
    lastImportError = null;
    importStatus = 'Opening ${p.basename(filePath)}...';
    notifyListeners();

    final fileName = p.basename(filePath);
    final ext = p.extension(filePath).toLowerCase();
    final isImage = const {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.heic',
    }.contains(ext);
    final isPdf = ext == '.pdf';
    if (!isPdf && !isImage) {
      importingFile = false;
      lastImportError = 'Unsupported file: $ext';
      _append('Import failed: $lastImportError');
      notifyListeners();
      return {'success': false, 'message': lastImportError};
    }

    try {
      String? sourceText;
      final imagePaths = <String>[];
      if (isPdf) {
        importStatus = 'Extracting text from $fileName...';
        notifyListeners();
        sourceText = await _extractPdfText(filePath);
        if (sourceText == null || sourceText.trim().isEmpty) {
          lastImportError =
              'No selectable text found in PDF. Try a non-scanned PDF or import as image.';
          _append('Import failed: $lastImportError');
          return {'success': false, 'message': lastImportError};
        }
        _append(
          'Extracted ${sourceText.length} chars from $fileName, drafting lesson...',
        );
      } else {
        imagePaths.add(filePath);
        _append('Drafting lesson from image $fileName...');
      }

      importStatus = 'Drafting lesson with on-device Gemma...';
      notifyListeners();

      final userContent = StringBuffer();
      if (sourceText != null) {
        const maxSourceChars = 6000;
        final clipped = sourceText.length > maxSourceChars
            ? '${sourceText.substring(0, maxSourceChars)}\n…[truncated, source was ${sourceText.length} chars]'
            : sourceText;
        userContent
          ..writeln('Source material from "$fileName":')
          ..writeln('---')
          ..writeln(clipped)
          ..writeln('---')
          ..writeln(
            'Draft a lesson with exactly $numSteps steps for $grade students based on this source. Stay close to the content above; do not invent unrelated facts. Return JSON only.',
          );
      } else {
        userContent.writeln(
          'The teacher uploaded the attached image "$fileName"${hint == null || hint.isEmpty ? '' : ' with the hint "$hint"'}.',
        );
        userContent.writeln(
          'Identify the key learning content visible in the image and draft a lesson with exactly $numSteps steps for $grade students based on it. Return JSON only.',
        );
      }

      final result = await boot.lm.generateCompletion(
        messages: [
          ChatMessage(role: 'system', content: _importLessonSystemPrompt),
          ChatMessage(
            role: 'user',
            content: userContent.toString(),
            images: imagePaths,
          ),
        ],
        params: CactusCompletionParams(maxTokens: 1400),
      );
      final lesson = LessonDraftParser.tryParse(
        modelOutput: result.text,
        fallbackTitle: p.basenameWithoutExtension(fileName),
        topic: hint ?? p.basenameWithoutExtension(fileName),
        grade: grade,
      );
      if (lesson == null) {
        lastImportError = 'Could not parse a lesson from the model output.';
        _append('Import failed: $lastImportError');
        return {'success': false, 'message': lastImportError};
      }
      replaceLesson(lesson);
      _append('Imported "${lesson.title}" (${lesson.steps.length} steps).');
      return {
        'success': true,
        'title': lesson.title,
        'numSteps': lesson.steps.length,
        'source': fileName,
      };
    } catch (e, st) {
      lastImportError = 'Import failed: $e';
      _append('Import threw: $e');
      debugPrint('$st');
      return {'success': false, 'message': lastImportError};
    } finally {
      importingFile = false;
      importStatus = null;
      notifyListeners();
    }
  }

  Future<String?> _extractPdfText(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    PdfDocument? doc;
    try {
      doc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(doc);
      final buffer = StringBuffer();
      for (var i = 0; i < doc.pages.count; i++) {
        final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i);
        if (pageText.trim().isEmpty) continue;
        buffer.writeln(pageText.trim());
        buffer.writeln();
      }
      return buffer.toString().trim();
    } finally {
      doc?.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> summarizeResponses({String? stepId}) async {
    final lesson = currentLesson;
    if (lesson == null) {
      return {'success': false, 'message': 'No lesson loaded.'};
    }
    final id = stepId ?? _stepIdForCurrent();
    if (id == null) {
      return {'success': false, 'message': 'No current step.'};
    }
    final session = currentSession;
    final responses = session == null
        ? <GradedResponse>[]
        : session.responses.where((r) => r.stepId == id).toList();
    final sample = responses.take(20).map((r) {
      final t = r.text.length > 200 ? '${r.text.substring(0, 200)}...' : r.text;
      return {
        'student':
            rosterStore?.resolveName(r.studentFingerprint, r.studentAlias) ??
            r.studentAlias,
        'answer': t,
        if (r.grade != null) 'grade': gradeToString(r.grade!),
      };
    }).toList();
    final step = lesson.steps.firstWhere(
      (s) => s.id == id,
      orElse: () => lesson.steps.first,
    );
    return {
      'success': true,
      'stepId': id,
      'stepPrompt': step.prompt,
      'totalResponses': responses.length,
      'sampleSize': sample.length,
      'truncatedPerResponse': 200,
      'responses': sample,
    };
  }

  @override
  Future<Map<String, dynamic>> pushPrompt({required int stepIndex}) async {
    final lesson = currentLesson;
    if (lesson == null) {
      return {'success': false, 'message': 'No lesson loaded.'};
    }
    if (stepIndex < 0 || stepIndex >= lesson.steps.length) {
      return {'success': false, 'message': 'stepIndex out of range.'};
    }
    if (!lessonRunning) {
      lessonRunning = true;
      _resetClassroomOutbox();
      _beginSessionFor(lesson);
      await _broadcastControl(
        ClassroomControl.now(
          lessonId: lesson.id,
          action: ControlAction.startLesson,
        ),
      );
    }
    await pushStep(stepIndex);
    return {
      'success': true,
      'pushedStepIndex': stepIndex,
      'studentsNotified': roster.length,
    };
  }

  @override
  Future<Map<String, dynamic>> nextStep() async {
    final lesson = currentLesson;
    if (lesson == null) {
      return {'success': false, 'message': 'No lesson loaded.'};
    }
    if (currentStepIndex + 1 >= lesson.steps.length) {
      return {
        'success': false,
        'message': 'Already on last step - call end_lesson instead.',
      };
    }
    await pushStep(currentStepIndex + 1);
    return {
      'success': true,
      'newStepIndex': currentStepIndex,
      'studentsNotified': roster.length,
    };
  }

  @override
  Future<Map<String, dynamic>> endLesson() async {
    if (currentLesson == null) {
      return {'success': false, 'message': 'No lesson loaded.'};
    }
    await endLessonUi();
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> currentLessonInfo() async {
    final lesson = currentLesson;
    if (lesson == null) {
      return {'success': true, 'lessonLoaded': false};
    }
    return {
      'success': true,
      'lessonLoaded': true,
      'title': lesson.title,
      'subject': lesson.subject,
      'topic': lesson.topic,
      'gradeLevel': lesson.gradeLevel,
      'numSteps': lesson.steps.length,
      'currentStepIndex': currentStepIndex,
      'lessonRunning': lessonRunning,
      'studentsConnected': roster.length,
      'steps': lesson.steps
          .map(
            (s) => {
              'index': s.index,
              'prompt': s.prompt,
              'expectedFormat': s.expectedFormat.name,
              'options': s.options,
              if (s.expectedAnswer != null) 'expectedAnswer': s.expectedAnswer,
            },
          )
          .toList(),
    };
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _stalePeerTimer?.cancel();
    multicast?.stop();
    server?.stop();
    pairRequests.close();
    super.dispose();
  }
}
