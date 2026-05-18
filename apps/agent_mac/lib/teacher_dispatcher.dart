import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:cactus/cactus.dart';

import 'automation_dispatcher.dart';

/// Callbacks the lesson tools invoke against the live AgentCore. Kept as a
/// thin interface so the dispatcher doesn't depend on Flutter state directly.
abstract class TeacherToolBridge {
  Future<Map<String, dynamic>> generateLesson({
    required String topic,
    required String grade,
    required int numSteps,
  });
  Future<Map<String, dynamic>> summarizeResponses({String? stepId});
  Future<Map<String, dynamic>> pushPrompt({required int stepIndex});
  Future<Map<String, dynamic>> nextStep();
  Future<Map<String, dynamic>> endLesson();
  Future<Map<String, dynamic>> currentLessonInfo();
}

/// Bundles macOS automation tools with classroom tools so big Gemma can call
/// either in the same ReactLoop turn ("open Calculator", "summarize
/// responses").
class TeacherDispatcher {
  final AutomationDispatcher automation;
  final TeacherToolBridge bridge;

  TeacherDispatcher({required this.automation, required this.bridge});

  static const _lessonToolSchemas = <Map<String, dynamic>>[
    {
      'name': 'generate_lesson',
      'description':
          'Draft a new interactive classroom lesson with `numSteps` student-facing prompts on the given topic and grade level. Replaces any lesson currently in the authoring pane. Use when the teacher asks to create, draft, or plan a lesson.',
      'parameters': {
        'type': 'object',
        'properties': {
          'topic': {
            'type': 'string',
            'description': 'Topic or learning target, e.g. "photosynthesis".',
          },
          'grade': {
            'type': 'string',
            'description':
                'Grade level or audience, e.g. "7th grade" or "intro college".',
          },
          'numSteps': {
            'type': 'integer',
            'description':
                'How many prompts the lesson should contain. Default 3.',
          },
        },
        'required': ['topic'],
      },
    },
    {
      'name': 'push_prompt',
      'description':
          'Send the lesson step at `stepIndex` (0-based) to every connected student phone now. Use when the teacher says "start", "go", "send step N", or after generating a lesson and starting class.',
      'parameters': {
        'type': 'object',
        'properties': {
          'stepIndex': {
            'type': 'integer',
            'description':
                '0-based index of the step to push. Use 0 for the first step.',
          },
        },
        'required': ['stepIndex'],
      },
    },
    {
      'name': 'next_step',
      'description':
          'Advance the class to the next lesson step and push it to all students. Use when the teacher says "next", "advance", or is ready to move on.',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'end_lesson',
      'description':
          'End the current lesson and tell all students to return to the idle screen. Use when the teacher says "stop", "end class", or "we are done".',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'summarize_responses',
      'description':
          'Return the student responses for a step (default: the current step), capped at 20 responses each truncated to ~200 chars to fit context. Call this before composing a summary, then write the summary as your final message.',
      'parameters': {
        'type': 'object',
        'properties': {
          'stepId': {
            'type': 'string',
            'description':
                'Optional. Step id to summarize. If omitted, the current step is used.',
          },
        },
      },
    },
    {
      'name': 'current_lesson_info',
      'description':
          'Inspect the lesson currently loaded in the authoring pane (title, subject, steps, formats, and prompts). Use this before push_prompt or next_step if you need to know what step you are on.',
      'parameters': {'type': 'object', 'properties': {}},
    },
  ];

  List<CactusTool> buildTools() => [
    ...automation.buildTools(),
    ..._lessonToolSchemas.map((j) => CactusTool.fromJson(j)),
  ];

  Future<Map<String, dynamic>> dispatch(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'generate_lesson':
        return bridge.generateLesson(
          topic: (args['topic'] ?? '').toString(),
          grade: (args['grade'] ?? 'general audience').toString(),
          numSteps: _asInt(args['numSteps']) ?? 3,
        );
      case 'push_prompt':
        return bridge.pushPrompt(stepIndex: _asInt(args['stepIndex']) ?? 0);
      case 'next_step':
        return bridge.nextStep();
      case 'end_lesson':
        return bridge.endLesson();
      case 'summarize_responses':
        final raw = args['stepId'];
        return bridge.summarizeResponses(
          stepId: raw is String && raw.isNotEmpty ? raw : null,
        );
      case 'current_lesson_info':
        return bridge.currentLessonInfo();
      default:
        return automation.dispatch(name, args);
    }
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}

/// Parses a model's free-form reply into a [Lesson]. The drafting prompt asks
/// for JSON, but Gemma sometimes wraps it in prose or fences, so we extract
/// the first balanced `{...}` block and decode it.
class LessonDraftParser {
  static Lesson? tryParse({
    required String modelOutput,
    required String fallbackTitle,
    required String topic,
    required String grade,
  }) {
    final obj = _extractJsonObject(modelOutput);
    if (obj == null) return null;
    final rawSteps = (obj['steps'] as List?) ?? const [];
    final steps = <LessonStep>[];
    for (var i = 0; i < rawSteps.length; i++) {
      final s = rawSteps[i];
      if (s is Map) {
        final prompt = (s['prompt'] ?? '').toString().trim();
        if (prompt.isEmpty) continue;
        final expectedFormat = _expectedFormatFromRaw(s['expectedFormat']);
        final options = expectedFormat == ExpectedFormat.multipleChoice
            ? _stringList(s['options'])
            : const <String>[];
        final usableFormat =
            expectedFormat == ExpectedFormat.multipleChoice &&
                options.length < 2
            ? ExpectedFormat.free
            : expectedFormat;
        final rawNotes = s['teacherNotes'];
        final teacherNotes = rawNotes is String && rawNotes.trim().isNotEmpty
            ? rawNotes.trim()
            : null;
        steps.add(
          LessonStep.create(
            index: steps.length,
            prompt: prompt,
            teacherNotes: teacherNotes,
            expectedFormat: usableFormat,
            options: usableFormat == ExpectedFormat.multipleChoice
                ? options
                : const <String>[],
          ),
        );
      } else if (s is String && s.trim().isNotEmpty) {
        steps.add(LessonStep.create(index: steps.length, prompt: s.trim()));
      }
    }
    if (steps.isEmpty) return null;
    final title = (obj['title'] as String?)?.trim();
    final subject = (obj['subject'] as String?)?.trim();
    return Lesson.create(
      title: (title == null || title.isEmpty) ? fallbackTitle : title,
      subject: subject == null || subject.isEmpty ? null : subject,
      topic: topic,
      gradeLevel: grade,
      steps: steps,
    );
  }

  static Map<String, dynamic>? _extractJsonObject(String src) {
    final start = src.indexOf('{');
    if (start < 0) return null;
    // Walk forward, tracking brace depth, ignoring braces inside strings.
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

  static ExpectedFormat _expectedFormatFromRaw(Object? raw) {
    switch (raw) {
      case 'short':
        return ExpectedFormat.short;
      case 'multipleChoice':
        return ExpectedFormat.multipleChoice;
      case 'free':
      default:
        return ExpectedFormat.free;
    }
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((option) => option.trim())
        .where((option) => option.isNotEmpty)
        .toList(growable: false);
  }
}
