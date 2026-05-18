import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'constants.dart';
import 'device_identity.dart';
import 'pairing_store.dart';
import 'peer.dart';

typedef IntentHandler =
    Future<IntentResponse> Function(IntentRequest req, LanPeer from);
typedef PromptHandler =
    Future<void> Function(LessonPrompt prompt, LanPeer from);
typedef ResponseHandler =
    Future<void> Function(StudentResponse response, LanPeer from);
typedef ControlHandler =
    Future<void> Function(ClassroomControl control, LanPeer from);
typedef ClassroomEventsHandler =
    Future<ClassroomEventBatch> Function(LanPeer from, int afterSequence);
typedef PendingPairCallback = Future<bool> Function(LanPeer candidate);

class LanAgentServer {
  final DeviceIdentity identity;
  final PairingStore pairing;
  final IntentHandler? onIntent;
  final PromptHandler? onPrompt;
  final ResponseHandler? onResponse;
  final ControlHandler? onControl;
  final ClassroomEventsHandler? onClassroomEvents;
  final PendingPairCallback? onPendingPair;

  HttpServer? _server;

  LanAgentServer({
    required this.identity,
    required this.pairing,
    this.onIntent,
    this.onPrompt,
    this.onResponse,
    this.onControl,
    this.onClassroomEvents,
    this.onPendingPair,
  });

  Future<void> start() async {
    if (_server != null) return;
    final router = Router()
      ..get(
        LanConst.healthPath,
        (Request req) => Response.ok(
          jsonEncode({
            'ok': true,
            'alias': identity.alias,
            'fingerprint': identity.fingerprint,
            'deviceType': DeviceIdentity.deviceType(),
            'port': LanConst.port,
          }),
          headers: {'content-type': 'application/json'},
        ),
      )
      ..get(
        LanConst.infoPath,
        (Request req) => Response.ok(
          jsonEncode({
            'alias': identity.alias,
            'fingerprint': identity.fingerprint,
            'deviceType': DeviceIdentity.deviceType(),
            'acceptsIntents': onIntent != null,
            'version': LanConst.protocolVersion,
            'port': LanConst.port,
            'protocol': LanConst.protocol,
          }),
          headers: {'content-type': 'application/json'},
        ),
      );

    if (onIntent != null) {
      router.post(LanConst.agentIntentPath, _handleIntent);
    }
    if (onPrompt != null) {
      router.post(LanConst.classroomPromptPath, _handlePrompt);
    }
    if (onResponse != null) {
      router.post(LanConst.classroomResponsePath, _handleResponse);
    }
    if (onControl != null) {
      router.post(LanConst.classroomControlPath, _handleControl);
    }
    if (onClassroomEvents != null) {
      router.get(LanConst.classroomEventsPath, _handleClassroomEvents);
    }

    _server = await shelf_io.serve(
      router.call,
      InternetAddress.anyIPv4,
      LanConst.port,
      shared: true,
    );
    debugPrint('LanAgentServer listening on :${_server!.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Verifies headers + pairing. Returns the resolved peer on success, or a
  /// Response (4xx) to short-circuit the request.
  Future<({LanPeer? peer, Response? reject})> _authorizePeer(
    Request req,
  ) async {
    final fingerprint = req.headers['x-lan-fingerprint'];
    final alias = req.headers['x-lan-alias'] ?? 'unknown';
    if (fingerprint == null) {
      return (
        peer: null,
        reject: Response(400, body: 'missing x-lan-fingerprint'),
      );
    }
    if (fingerprint == identity.fingerprint) {
      return (peer: null, reject: Response(409, body: 'refusing self-intent'));
    }

    final ip =
        (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)
            ?.remoteAddress
            .address ??
        'unknown';
    final deviceType = req.headers['x-lan-device-type'] ?? 'unknown';
    final candidate = LanPeer(
      alias: alias,
      fingerprint: fingerprint,
      ip: ip,
      port: LanConst.port,
      deviceType: deviceType,
      acceptsIntents: req.headers['x-lan-accepts-intents'] == 'true',
      lastSeen: DateTime.now(),
    );

    if (!pairing.isTrusted(fingerprint)) {
      final cb = onPendingPair;
      if (cb == null) {
        return (
          peer: null,
          reject: Response.forbidden('unpaired peer; no approval UI wired'),
        );
      }
      final ok = await cb(candidate);
      if (!ok) {
        return (
          peer: null,
          reject: Response.forbidden('user declined pairing'),
        );
      }
      await pairing.trust(candidate);
    }
    return (peer: candidate, reject: null);
  }

  Future<Response> _handleIntent(Request req) async {
    final auth = await _authorizePeer(req);
    if (auth.reject != null) return auth.reject!;
    final handler = onIntent;
    if (handler == null) return Response.notFound('intent endpoint disabled');

    try {
      final body = await req.readAsString();
      final intent = IntentRequest.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
      final response = await handler(intent, auth.peer!);
      return Response.ok(
        jsonEncode(response.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, st) {
      debugPrint('LanAgentServer intent handling failed: $e');
      debugPrint('$st');
      return Response.internalServerError(body: 'intent handler failed: $e');
    }
  }

  Future<Response> _handlePrompt(Request req) async {
    final auth = await _authorizePeer(req);
    if (auth.reject != null) return auth.reject!;
    final body = await req.readAsString();
    final prompt = LessonPrompt.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
    unawaited(onPrompt!(prompt, auth.peer!));
    return Response(
      202,
      body: '{}',
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _handleResponse(Request req) async {
    final auth = await _authorizePeer(req);
    if (auth.reject != null) return auth.reject!;
    final body = await req.readAsString();
    final resp = StudentResponse.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
    unawaited(onResponse!(resp, auth.peer!));
    return Response(
      202,
      body: '{}',
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _handleControl(Request req) async {
    final auth = await _authorizePeer(req);
    if (auth.reject != null) return auth.reject!;
    final body = await req.readAsString();
    final ctrl = ClassroomControl.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
    unawaited(onControl!(ctrl, auth.peer!));
    return Response(
      202,
      body: '{}',
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _handleClassroomEvents(Request req) async {
    final auth = await _authorizePeer(req);
    if (auth.reject != null) return auth.reject!;
    final handler = onClassroomEvents;
    if (handler == null) {
      return Response.notFound('classroom events endpoint disabled');
    }

    try {
      final afterSequence =
          int.tryParse(req.url.queryParameters['after'] ?? '') ?? 0;
      final batch = await handler(auth.peer!, afterSequence);
      return Response.ok(
        jsonEncode(batch.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, st) {
      debugPrint('LanAgentServer classroom events failed: $e');
      debugPrint('$st');
      return Response.internalServerError(body: 'classroom events failed: $e');
    }
  }
}
