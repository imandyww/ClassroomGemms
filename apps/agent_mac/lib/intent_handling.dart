import 'package:agent_llm/agent_llm.dart';
import 'package:agent_protocol/agent_protocol.dart';

const List<String> spotlightFastPathKeys = ['leftCommand', 'space'];

class IntentFastPath {
  const IntentFastPath({
    required this.name,
    required this.toolName,
    required this.toolArguments,
    required this.successText,
  });

  final String name;
  final String toolName;
  final Map<String, dynamic> toolArguments;
  final String successText;
}

IntentFastPath? matchIntentFastPath(String text) {
  final normalized = _normalizeIntent(text);
  const spotlightCommands = {
    'open spotlight',
    'open the spotlight',
    'show spotlight',
    'show the spotlight',
    'bring up spotlight',
    'bring up the spotlight',
  };
  if (spotlightCommands.contains(normalized)) {
    return const IntentFastPath(
      name: 'spotlight',
      toolName: 'pressKeys',
      toolArguments: {'keys': spotlightFastPathKeys},
      successText: 'Opened Spotlight.',
    );
  }
  return null;
}

IntentResponse buildIntentResponseFromRun({
  required IntentRequest request,
  required AgentRun run,
  required String modelSlug,
  required bool isFallback,
  void Function(String line)? onLog,
}) {
  if (run.trace.isEmpty) {
    onLog?.call(
      buildNoMacActionDiagnostic(
        intentText: request.text,
        finalText: run.finalText,
        modelSlug: modelSlug,
        isFallback: isFallback,
      ),
    );
  }

  return IntentResponse(
    correlationId: request.correlationId,
    success: run.success,
    text: run.finalText,
    trace: run.trace,
  );
}

String buildNoMacActionDiagnostic({
  required String intentText,
  required String finalText,
  required String modelSlug,
  required bool isFallback,
}) {
  final compactIntent = _compact(intentText);
  final compactFinal = _compact(finalText);
  return 'Warning: model completed without tool calls. '
      'intent="$compactIntent" '
      'model=$modelSlug '
      'fallback=${isFallback ? 'yes' : 'no'} '
      'final="$compactFinal" '
      'No macOS action executed.';
}

String _normalizeIntent(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _compact(String text) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '(empty)';
  if (normalized.length <= 120) return normalized;
  return '${normalized.substring(0, 117)}...';
}
