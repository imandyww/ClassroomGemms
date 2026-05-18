import 'tool_call_trace.dart';

class IntentResponse {
  final String correlationId;
  final bool success;
  final String text;
  final List<ToolCallTrace> trace;
  final String? errorCode;

  IntentResponse({
    required this.correlationId,
    required this.success,
    required this.text,
    this.trace = const [],
    this.errorCode,
  });

  factory IntentResponse.fromJson(Map<String, dynamic> j) => IntentResponse(
        correlationId: j['correlationId'] as String,
        success: j['success'] as bool,
        text: j['text'] as String,
        trace: (j['trace'] as List? ?? const [])
            .map((e) => ToolCallTrace.fromJson(e as Map<String, dynamic>))
            .toList(),
        errorCode: j['errorCode'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'correlationId': correlationId,
        'success': success,
        'text': text,
        'trace': trace.map((e) => e.toJson()).toList(),
        if (errorCode != null) 'errorCode': errorCode,
      };
}
