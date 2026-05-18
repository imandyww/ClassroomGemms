import 'package:automation_core/automation_core.dart';
import 'package:cactus/cactus.dart';

/// Maps a Gemma tool call to the right AutomationService method, coercing
/// stringly-typed Cactus [ToolCall.arguments] into the expected Dart types.
class AutomationDispatcher {
  final AutomationService service;

  AutomationDispatcher(this.service);

  /// Gemma-facing tool list. Parsed from our `automation_core` JSON schemas
  /// via `CactusTool.fromJson`.
  List<CactusTool> buildTools() =>
      buildToolSchemas().map((j) => CactusTool.fromJson(j)).toList();

  Future<Map<String, dynamic>> dispatch(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'captureScreenshot':
        return service.captureScreenshot();
      case 'detectElementPosition':
        return service.detectElementPosition(
          elementDescription: (args['elementDescription'] ?? '').toString(),
        );
      case 'moveMouse':
        return service.moveMouse(
          x: _asInt(args['x']) ?? 0,
          y: _asInt(args['y']) ?? 0,
        );
      case 'clickMouse':
        return service.clickMouse(
          button: (args['button'] ?? 'left').toString(),
          action: (args['action'] ?? 'click').toString(),
        );
      case 'typeText':
        return service.typeText(text: (args['text'] ?? '').toString());
      case 'pressKeys':
        final keys = _asList(args['keys']);
        return service.pressKeys(keys: keys.map((e) => e.toString()).toList());
      case 'wait':
        return service.wait(seconds: _asDouble(args['seconds']) ?? 0.5);
      case 'getShortcuts':
        return service.getShortcuts(query: (args['query'] ?? '').toString());
      case 'askUser':
        return service.askUser(question: (args['question'] ?? '').toString());
      case 'createCalendarEvent':
        return service.createCalendarEvent(
          title: (args['title'] ?? '').toString(),
          date: (args['date'] ?? '').toString(),
          startTime: (args['startTime'] ?? '09:00').toString(),
          durationMinutes: _asInt(args['durationMinutes']) ?? 30,
          notes: (args['notes'] ?? '').toString(),
          calendarName: (args['calendarName'] ?? '').toString(),
          allDay: _asBool(args['allDay']) ?? false,
        );
      default:
        return {'success': false, 'message': 'Unknown tool: $name'};
    }
  }

  bool? _asBool(dynamic v) {
    if (v == null) return null;
    if (v is bool) return v;
    final s = v.toString().toLowerCase().trim();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return null;
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  List<dynamic> _asList(dynamic v) {
    if (v == null) return const [];
    if (v is List) return v;
    if (v is String) {
      // Cactus may serialize arrays as stringified JSON.
      try {
        final t = v.trim();
        if (t.startsWith('[') && t.endsWith(']')) {
          return t
              .substring(1, t.length - 1)
              .split(',')
              .map((s) => s.trim().replaceAll(RegExp('^[\'"]|[\'"]\$'), ''))
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {}
      return [v];
    }
    return [v];
  }
}
