import 'dart:async';
import 'dart:io';

import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:automation_core/automation_core.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:lan_transport/lan_transport.dart';

import 'automation_dispatcher.dart';
import 'lesson_store.dart';
import 'teacher_dispatcher.dart';

enum TeacherChatMode { author, automation }
enum StudentSessionState { connected, answering, answered, disconnected }

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
  TeacherChatTurn({required this.userText, required this.replyText, required this.trace});
}

class AgentCore extends ChangeNotifier implements TeacherToolBridge {
  DeviceIdentity? identity;
  PairingStore? pairing;
  MulticastService? multicast;
  LanAgentServer? server;
  LanAgentClient? client;
  AutomationService? automation;
  AutomationDispatcher? automationDispatcher;
  TeacherDispatcher? teacherDispatcher;
  LmBootstrap? lmBoot;
  PickedModel? loadedModel;
  ReactLoop? _react;
  LessonStore? lessonStore;

  // --- classroom session state ---
  Lesson? currentLesson;
  int currentStepIndex = -1; // -1 = not started
  bool lessonRunning = false;
  final Map<String, StudentSlot> roster = {}; // fingerprint -> slot
  // stepId -> fingerprint -> response
  final Map<String, Map<String, StudentResponse>> responsesByStep = {};

  // --- teacher chat state ---
  TeacherChatMode chatMode = TeacherChatMode.author;
  final List<TeacherChatTurn> chatHistory = [];
  bool chatBusy = false;

  /// Non-loopback IPv4 addresses, surfaced in the UI so the teacher can punch
  /// one into the Simulator's "Add manual peer" field.
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
    identity = await DeviceIdentity.loadOrCreate(defaultAlias: 'Teacher-Mac');
    pairing = await PairingStore.open();
    lessonStore = await LessonStore.open();
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
    client = LanAgentClient(identity: identity!);

    server = LanAgentServer(
      identity: identity!,
      pairing: pairing!,
      onResponse: _handleStudentResponse,
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
        // Filter to phones/mobile devices for the classroom roster.
        if (peer.deviceType == 'mobile') {
          final isNew = !roster.containsKey(peer.fingerprint);
          final existing = roster[peer.fingerprint];
          roster[peer.fingerprint] = StudentSlot(
            peer: peer,
            state: existing?.state == StudentSessionState.answered &&
                    _stepIdForCurrent() == (existing?.lastResponse?.stepId)
                ? StudentSessionState.answered
                : StudentSessionState.connected,
            lastResponse: existing?.lastResponse,
          );
          if (isNew) _append('Student joined: ${peer.alias} @ ${peer.ip}');
          notifyListeners();
        }
      },
    );
    try {
      await multicast!.start();
      _append('Multicast discovery started');
    } catch (e) {
      _append('Multicast failed: $e (unicast still works)');
    }

    unawaited(refreshLocalIps());
    notifyListeners();
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

  // ---------------- Teacher chat ----------------

  String _systemPromptFor(TeacherChatMode mode) {
    final now = DateTime.now();
    final iso =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
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
- The macOS automation tools (Spotlight, keyboard, calendar) are also available — use them only when the teacher explicitly asks for a desktop action like opening an app or adding a calendar entry.
- When the user's request is satisfied, reply with a short natural-language sentence and NO tool calls.
''';
      case TeacherChatMode.automation:
        return '''
You are a macOS automation agent. Today is $iso ($weekday). Use this to resolve relative dates the user mentions into absolute YYYY-MM-DD values. Pick the most direct tool, do not improvise:
- For any scheduling / reminder / calendar request → call `createCalendarEvent` ONCE with a clean title and resolved date.
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
      chatHistory.add(TeacherChatTurn(
        userText: text,
        replyText: run.finalText,
        trace: run.trace,
      ));
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
    currentLesson = lesson;
    currentStepIndex = -1;
    lessonRunning = false;
    responsesByStep.clear();
    for (final slot in roster.values) {
      slot.state = StudentSessionState.connected;
      slot.lastResponse = null;
    }
    unawaited(lessonStore?.save(lesson) ?? Future.value());
    _append('Loaded lesson "${lesson.title}" (${lesson.steps.length} steps).');
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
    responsesByStep.clear();
    final ctrl = ClassroomControl.now(
      lessonId: lesson.id,
      action: ControlAction.startLesson,
    );
    await _broadcastControl(ctrl);
    await pushStep(0);
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
    );
    for (final slot in roster.values) {
      slot.state = StudentSessionState.answering;
      slot.lastResponse = null;
    }
    notifyListeners();

    final peers = roster.values.map((s) => s.peer).toList();
    if (peers.isEmpty) {
      _append('No students connected — prompt staged but not pushed.');
      return;
    }
    for (final peer in peers) {
      final ok = await c.pushPrompt(peer: peer, prompt: prompt);
      if (!ok) {
        roster[peer.fingerprint]?.state = StudentSessionState.disconnected;
        _append('Push to ${peer.alias} failed.');
      }
    }
    _append('Pushed step ${index + 1}/${lesson.steps.length} to ${peers.length} student(s).');
    notifyListeners();
  }

  Future<void> nextStepUi() async {
    final lesson = currentLesson;
    if (lesson == null) return;
    if (currentStepIndex + 1 >= lesson.steps.length) {
      _append('Already on last step — call End Lesson when done.');
      return;
    }
    await pushStep(currentStepIndex + 1);
  }

  Future<void> endLessonUi() async {
    final lesson = currentLesson;
    if (lesson == null) return;
    lessonRunning = false;
    currentStepIndex = -1;
    await _broadcastControl(ClassroomControl.now(
      lessonId: lesson.id,
      action: ControlAction.endLesson,
    ));
    for (final slot in roster.values) {
      slot.state = StudentSessionState.connected;
    }
    _append('Lesson ended.');
    notifyListeners();
  }

  Future<void> _broadcastControl(ClassroomControl ctrl) async {
    final c = client;
    if (c == null) return;
    final peers = roster.values.map((s) => s.peer).toList();
    for (final peer in peers) {
      final ok = await c.sendControl(peer: peer, control: ctrl);
      if (!ok) roster[peer.fingerprint]?.state = StudentSessionState.disconnected;
    }
  }

  String? _stepIdForCurrent() {
    final lesson = currentLesson;
    if (lesson == null) return null;
    if (currentStepIndex < 0 || currentStepIndex >= lesson.steps.length) return null;
    return lesson.steps[currentStepIndex].id;
  }

  Future<void> _handleStudentResponse(StudentResponse resp, LanPeer from) async {
    final byStep = responsesByStep.putIfAbsent(resp.stepId, () => {});
    byStep[resp.studentFingerprint] = resp;
    final slot = roster[resp.studentFingerprint];
    if (slot != null) {
      slot.state = StudentSessionState.answered;
      slot.lastResponse = resp;
    } else {
      // Student we didn't see in multicast yet — add them.
      roster[resp.studentFingerprint] = StudentSlot(
        peer: from,
        state: StudentSessionState.answered,
        lastResponse: resp,
      );
    }
    _append('Response from ${resp.studentAlias} (${resp.text.length} chars).');
    notifyListeners();
  }

  // ---------------- TeacherToolBridge ----------------

  static const _lessonDraftSystemPrompt = '''
You draft interactive classroom lessons. Output ONLY a single JSON object — no prose, no code fences. Schema:
{
  "title": string,
  "steps": [
    { "prompt": string, "teacherNotes": string }
  ]
}
The prompt is the question the student sees. Keep each prompt under 200 characters and answerable in a few sentences. Make prompts open-ended, not yes/no. Sequence them from concrete to more abstract.
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
        'numSteps': lesson.steps.length,
        'steps': lesson.steps.map((s) => s.prompt).toList(),
      };
    } catch (e) {
      return {'success': false, 'message': 'Draft failed: $e'};
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
    final byFp = responsesByStep[id] ?? const <String, StudentResponse>{};
    final entries = byFp.values.toList().take(20).toList();
    // Truncate each response to keep context under E4B's 4096-token window.
    final sample = entries.map((r) {
      final t = r.text.length > 200 ? '${r.text.substring(0, 200)}…' : r.text;
      return {'student': r.studentAlias, 'answer': t};
    }).toList();
    final step = lesson.steps.firstWhere(
      (s) => s.id == id,
      orElse: () => lesson.steps.first,
    );
    return {
      'success': true,
      'stepId': id,
      'stepPrompt': step.prompt,
      'totalResponses': byFp.length,
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
      await _broadcastControl(ClassroomControl.now(
        lessonId: lesson.id,
        action: ControlAction.startLesson,
      ));
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
        'message': 'Already on last step — call end_lesson instead.',
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
      'topic': lesson.topic,
      'gradeLevel': lesson.gradeLevel,
      'numSteps': lesson.steps.length,
      'currentStepIndex': currentStepIndex,
      'lessonRunning': lessonRunning,
      'studentsConnected': roster.length,
      'steps': lesson.steps
          .map((s) => {'index': s.index, 'prompt': s.prompt})
          .toList(),
    };
  }

  @override
  void dispose() {
    multicast?.stop();
    server?.stop();
    pairRequests.close();
    super.dispose();
  }
}
