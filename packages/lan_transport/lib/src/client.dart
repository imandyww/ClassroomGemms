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

/// Ships an [IntentRequest] to a peer and waits for its [IntentResponse].
/// Uses our custom /agent/v1/intent endpoint (JSON in, JSON out) — the
/// LocalSend /prepare-upload + /upload dance is skipped since we control
/// both ends.
class LanAgentClient {
  final DeviceIdentity identity;
  final Duration timeout;
  final Duration classroomTimeout;

  LanAgentClient({
    required this.identity,
    this.timeout = const Duration(minutes: 2),
    this.classroomTimeout = const Duration(seconds: 5),
  });

  Future<AgentSendResult> sendIntent({
    required LanPeer peer,
    required IntentRequest request,
  }) async {
    final uri = Uri.parse('${peer.baseUrl}${LanConst.agentIntentPath}');
    try {
      final resp = await http
          .post(
            uri,
            headers: _headers(),
            body: jsonEncode(request.toJson()),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) {
        return AgentSendResult(success: false, error: 'HTTP ${resp.statusCode}: ${resp.body}');
      }
      final decoded = IntentResponse.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      return AgentSendResult(success: true, response: decoded);
    } catch (e) {
      return AgentSendResult(success: false, error: e.toString());
    }
  }

  /// Teacher → student: push the current step's prompt.
  Future<bool> pushPrompt({
    required LanPeer peer,
    required LessonPrompt prompt,
  }) =>
      _postClassroom(peer, LanConst.classroomPromptPath, prompt.toJson());

  /// Student → teacher: submit an answer for the current step.
  Future<bool> submitResponse({
    required LanPeer peer,
    required StudentResponse response,
  }) =>
      _postClassroom(peer, LanConst.classroomResponsePath, response.toJson());

  /// Teacher → student: start / advance / end the lesson.
  Future<bool> sendControl({
    required LanPeer peer,
    required ClassroomControl control,
  }) =>
      _postClassroom(peer, LanConst.classroomControlPath, control.toJson());

  Future<bool> _postClassroom(LanPeer peer, String path, Map<String, dynamic> body) async {
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
      };
}
