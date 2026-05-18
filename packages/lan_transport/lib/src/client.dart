import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;

import 'constants.dart';
import 'device_identity.dart';
import 'peer.dart';

class AgentSendResult {
  final bool success;
  final IntentResponse? response;
  final String? error;

  AgentSendResult({required this.success, this.response, this.error});
}

/// Ships requests between LAN peers using the small JSON endpoints hosted by
/// [LanAgentServer].
class LanAgentClient {
  final DeviceIdentity identity;
  final bool acceptsIntents;
  final Duration timeout;
  final Duration classroomTimeout;

  LanAgentClient({
    required this.identity,
    required this.acceptsIntents,
    this.timeout = const Duration(minutes: 2),
    this.classroomTimeout = const Duration(seconds: 5),
  });

  Future<AgentSendResult> sendIntent({
    required LanPeer peer,
    required IntentRequest request,
  }) async {
    if (peer.fingerprint == identity.fingerprint) {
      return AgentSendResult(
        success: false,
        error: 'Refusing to send intent to self (${peer.alias}).',
      );
    }
    if (!peer.acceptsIntents) {
      return AgentSendResult(
        success: false,
        error:
            'Peer ${peer.alias} is send-only and does not host ${LanConst.agentIntentPath}.',
      );
    }

    final uri = Uri.parse('${peer.baseUrl}${LanConst.agentIntentPath}');
    try {
      final resp = await http
          .post(uri, headers: _headers(), body: jsonEncode(request.toJson()))
          .timeout(timeout);
      if (resp.statusCode != 200) {
        return AgentSendResult(
          success: false,
          error: 'HTTP ${resp.statusCode}: ${resp.body}',
        );
      }
      final decoded = IntentResponse.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
      return AgentSendResult(success: true, response: decoded);
    } catch (e) {
      return AgentSendResult(success: false, error: e.toString());
    }
  }

  /// Teacher -> student: push the current step's prompt.
  Future<bool> pushPrompt({
    required LanPeer peer,
    required LessonPrompt prompt,
  }) => _postClassroom(peer, LanConst.classroomPromptPath, prompt.toJson());

  /// Student -> teacher: submit an answer for the current step.
  Future<bool> submitResponse({
    required LanPeer peer,
    required StudentResponse response,
  }) => _postClassroom(peer, LanConst.classroomResponsePath, response.toJson());

  /// Teacher -> student: start / advance / end the lesson.
  Future<bool> sendControl({
    required LanPeer peer,
    required ClassroomControl control,
  }) => _postClassroom(peer, LanConst.classroomControlPath, control.toJson());

  /// Student -> teacher: pull classroom events as a fallback for environments
  /// where teacher -> student HTTP is not routable, such as iOS Simulator.
  Future<ClassroomEventBatch?> pollClassroomEvents({
    required LanPeer peer,
    required int afterSequence,
  }) async {
    final uri = Uri.parse(
      '${peer.baseUrl}${LanConst.classroomEventsPath}',
    ).replace(queryParameters: {'after': '$afterSequence'});
    try {
      final resp = await http
          .get(uri, headers: _headers())
          .timeout(classroomTimeout);
      if (resp.statusCode != 200) return null;
      return ClassroomEventBatch.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _postClassroom(
    LanPeer peer,
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('${peer.baseUrl}$path');
    try {
      final resp = await http
          .post(uri, headers: _headers(), body: jsonEncode(body))
          .timeout(classroomTimeout);
      return resp.statusCode == 200 || resp.statusCode == 202;
    } catch (_) {
      return false;
    }
  }

  Map<String, String> _headers() => {
    'content-type': 'application/json',
    'x-lan-fingerprint': identity.fingerprint,
    'x-lan-alias': identity.alias,
    'x-lan-device-type': DeviceIdentity.deviceType(),
    'x-lan-accepts-intents': '$acceptsIntents',
  };
}
