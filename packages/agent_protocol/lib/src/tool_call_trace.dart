class ToolCallTrace {
  final String toolName;
  final Map<String, dynamic> args;
  final Map<String, dynamic> result;
  final int ms;

  ToolCallTrace({
    required this.toolName,
    required this.args,
    required this.result,
    required this.ms,
  });

  factory ToolCallTrace.fromJson(Map<String, dynamic> j) => ToolCallTrace(
        toolName: j['toolName'] as String,
        args: Map<String, dynamic>.from(j['args'] as Map? ?? const {}),
        result: Map<String, dynamic>.from(j['result'] as Map? ?? const {}),
        ms: j['ms'] as int,
      );

  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'args': args,
        'result': result,
        'ms': ms,
      };
}
