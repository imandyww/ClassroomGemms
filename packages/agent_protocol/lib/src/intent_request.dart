import 'package:uuid/uuid.dart';

class IntentRequest {
  final String correlationId;
  final String text;
  final String sourceDevice;
  final int createdAtMs;

  IntentRequest({
    required this.correlationId,
    required this.text,
    required this.sourceDevice,
    required this.createdAtMs,
  });

  factory IntentRequest.create({required String text, required String sourceDevice}) =>
      IntentRequest(
        correlationId: const Uuid().v4(),
        text: text,
        sourceDevice: sourceDevice,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  factory IntentRequest.fromJson(Map<String, dynamic> j) => IntentRequest(
        correlationId: j['correlationId'] as String,
        text: j['text'] as String,
        sourceDevice: j['sourceDevice'] as String,
        createdAtMs: j['createdAtMs'] as int,
      );

  Map<String, dynamic> toJson() => {
        'correlationId': correlationId,
        'text': text,
        'sourceDevice': sourceDevice,
        'createdAtMs': createdAtMs,
      };
}
