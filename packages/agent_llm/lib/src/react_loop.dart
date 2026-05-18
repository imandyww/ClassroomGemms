import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';

typedef ToolDispatch = Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> args);
typedef AgentStatusCb = void Function(String step);

class AgentRun {
  final bool success;
  final String finalText;
  final List<ToolCallTrace> trace;

  AgentRun({required this.success, required this.finalText, required this.trace});
}

class ReactLoop {
  final CactusLM lm;

  ReactLoop({required this.lm});

  Future<AgentRun> run({
    required List<ChatMessage> messages,
    required List<CactusTool> tools,
    required ToolDispatch dispatch,
    int maxSteps = 8,
    AgentStatusCb? onStatus,
  }) async {
    final history = List<ChatMessage>.from(messages);
    final trace = <ToolCallTrace>[];

    for (var step = 0; step < maxSteps; step++) {
      onStatus?.call('Step ${step + 1}: generating...');
      final result = await lm.generateCompletion(
        messages: history,
        params: CactusCompletionParams(tools: tools, maxTokens: 512),
      );

      if (!result.success) {
        return AgentRun(success: false, finalText: result.response, trace: trace);
      }

      if (result.toolCalls.isEmpty) {
        return AgentRun(success: true, finalText: result.response, trace: trace);
      }

      history.add(ChatMessage(role: 'assistant', content: result.response));

      for (final call in result.toolCalls) {
        final stopwatch = Stopwatch()..start();
        onStatus?.call('Step ${step + 1}: calling ${call.name}(${_compact(call.arguments)})');
        Map<String, dynamic> toolResult;
        try {
          toolResult = await dispatch(call.name, call.arguments);
        } catch (e) {
          toolResult = {'success': false, 'message': 'dispatch threw: $e'};
        }
        stopwatch.stop();
        trace.add(ToolCallTrace(
          toolName: call.name,
          args: call.arguments,
          result: toolResult,
          ms: stopwatch.elapsedMilliseconds,
        ));
        history.add(ChatMessage(
          role: 'tool',
          content: jsonEncode({'name': call.name, 'result': toolResult}),
        ));
      }
    }

    debugPrint('ReactLoop hit max steps ($maxSteps).');
    return AgentRun(
      success: false,
      finalText: 'Agent reached max step budget ($maxSteps). Last tool trace: ${trace.isEmpty ? 'none' : trace.last.toolName}',
      trace: trace,
    );
  }

  String _compact(Map<String, dynamic> args) {
    final j = jsonEncode(args);
    if (j.length <= 60) return j;
    return '${j.substring(0, 57)}...';
  }
}
