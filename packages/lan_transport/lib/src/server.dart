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

typedef IntentHandler = Future<IntentResponse> Function(IntentRequest req, LanPeer from);
typedef PendingPairCallback = Future<bool> Function(LanPeer candidate);

class LanAgentServer {
  final DeviceIdentity identity;
  final PairingStore pairing;
  final IntentHandler onIntent;
  final PendingPairCallback? onPendingPair;

  HttpServer? _server;

  LanAgentServer({
    required this.identity,
    required this.pairing,
    required this.onIntent,
    this.onPendingPair,
  });

  Future<void> start() async {
    if (_server != null) return;
    final router = Router()
      ..get(LanConst.infoPath, (Request req) => Response.ok(
            jsonEncode({
              'alias': identity.alias,
              'fingerprint': identity.fingerprint,
              'deviceType': DeviceIdentity.deviceType(),
              'version': LanConst.protocolVersion,
              'port': LanConst.port,
              'protocol': LanConst.protocol,
            }),
            headers: {'content-type': 'application/json'},
          ))
      ..post(LanConst.agentIntentPath, _handleIntent);

    _server = await shelf_io.serve(router.call, InternetAddress.anyIPv4, LanConst.port, shared: true);
    debugPrint('LanAgentServer listening on :${_server!.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _handleIntent(Request req) async {
    final fingerprint = req.headers['x-lan-fingerprint'];
    final alias = req.headers['x-lan-alias'] ?? 'unknown';
    if (fingerprint == null) {
      return Response(400, body: 'missing x-lan-fingerprint');
    }
    final ip = (req.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address
        ?? 'unknown';
    final candidate = LanPeer(
      alias: alias,
      fingerprint: fingerprint,
      ip: ip,
      port: LanConst.port,
      deviceType: 'unknown',
      lastSeen: DateTime.now(),
    );

    if (!pairing.isTrusted(fingerprint)) {
      final cb = onPendingPair;
      if (cb == null) {
        return Response.forbidden('unpaired peer; no approval UI wired');
      }
      final ok = await cb(candidate);
      if (!ok) return Response.forbidden('user declined pairing');
      await pairing.trust(candidate);
    }

    final body = await req.readAsString();
    final intent = IntentRequest.fromJson(jsonDecode(body) as Map<String, dynamic>);
    final response = await onIntent(intent, candidate);
    return Response.ok(jsonEncode(response.toJson()), headers: {'content-type': 'application/json'});
  }
}
