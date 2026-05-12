/// LocalSend-compatible defaults. We keep the port/multicast group so stock
/// LocalSend clients on the same LAN can still discover us if needed, but our
/// app-to-app exchange uses our own /agent/v1 endpoints.
class LanConst {
  static const int port = 53317;
  static const String multicastGroup = '224.0.0.167';
  static const String protocolVersion = '2.1';
  static const String protocol = 'http'; // MVP: plaintext on trusted LAN

  // LocalSend-compatible endpoints (kept for future compat)
  static const String infoPath = '/api/localsend/v2/info';
  static const String registerPath = '/api/localsend/v2/register';
  static const String prepareUploadPath = '/api/localsend/v2/prepare-upload';
  static const String uploadPath = '/api/localsend/v2/upload';

  // Our own endpoint — carries IntentRequest/IntentResponse as JSON.
  // Kept in place during the classroom-app migration; remove once both
  // apps stop using it.
  static const String agentIntentPath = '/agent/v1/intent';

  // Classroom: teacher → student push (prompts, control) and student → teacher
  // (responses). Fire-and-forget JSON POSTs; session state lives in the app.
  static const String classroomPromptPath = '/classroom/v1/prompt';
  static const String classroomResponsePath = '/classroom/v1/response';
  static const String classroomControlPath = '/classroom/v1/control';
}
