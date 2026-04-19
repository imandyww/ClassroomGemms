import 'dart:io';
import 'dart:typed_data';

import 'package:bixat_key_mouse/bixat_key_mouse.dart';
import 'package:image/image.dart' as img;
import 'package:screen_capturer/screen_capturer.dart';

typedef StatusCallback = void Function(String message);
typedef ScreenshotCallback = void Function();

/// macOS automation tool surface, adapted from NextDesk's AutomationService.
/// Vision-based detection, shortcut lookup, and askUser are stubbed in MVP —
/// they succeed with a "not implemented" payload so the ReAct loop doesn't crash.
class AutomationService {
  final StatusCallback onStatusUpdate;
  final ScreenshotCallback onScreenshotTaken;
  final ScreenCapturer _screenCapturer = ScreenCapturer.instance;

  Uint8List? lastScreenshot;

  AutomationService({
    required this.onStatusUpdate,
    required this.onScreenshotTaken,
  });

  Future<Map<String, dynamic>> captureScreenshot() async {
    try {
      final capturedImage = await _screenCapturer.capture(mode: CaptureMode.screen);
      if (capturedImage != null) {
        final full = capturedImage.imageBytes;
        if (full != null) {
          lastScreenshot = await _resizeImage(full) ?? full;
          onScreenshotTaken();
          return {
            'success': true,
            'message': 'Screenshot captured successfully',
            'hasImage': true,
          };
        }
      }
      return {'success': false, 'message': 'Failed to capture screenshot'};
    } catch (e) {
      return {'success': false, 'message': 'Error capturing screenshot: $e'};
    }
  }

  Future<Uint8List?> _resizeImage(Uint8List bytes) async {
    try {
      final image = img.decodeImage(bytes);
      if (image == null) return null;
      final resized = img.copyResize(
        image,
        width: (image.width / 3).toInt(),
        height: (image.height / 3).toInt(),
      );
      return img.encodePng(resized);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> detectElementPosition({required String elementDescription}) async {
    // MVP: not implemented. Gemma-3n vision integration lands in a later milestone.
    return {
      'success': false,
      'message': 'detectElementPosition is not implemented in MVP; use keyboard shortcuts or absolute coordinates instead.',
      'element_description': elementDescription,
    };
  }

  Map<String, dynamic> moveMouse({required int x, required int y}) {
    try {
      BixatKeyMouse.moveMouse(x: x, y: y);
      return {'success': true, 'message': 'Mouse moved to ($x, $y)', 'position': {'x': x, 'y': y}};
    } catch (e) {
      return {'success': false, 'message': 'Error moving mouse: $e'};
    }
  }

  Map<String, dynamic> clickMouse({String button = 'left', String action = 'click'}) {
    try {
      final mouseButton = switch (button.toLowerCase()) {
        'left' => MouseButton.left,
        'middle' => MouseButton.middle,
        _ => MouseButton.right,
      };
      BixatKeyMouse.pressMouseButton(button: mouseButton, direction: Direction.click);
      return {'success': true, 'message': 'Mouse $button button $action successful', 'button': button, 'action': action};
    } catch (e) {
      return {'success': false, 'message': 'Error clicking mouse: $e'};
    }
  }

  Map<String, dynamic> typeText({required String text}) {
    try {
      BixatKeyMouse.enterText(text: text);
      return {'success': true, 'message': 'Text typed successfully', 'text': text};
    } catch (e) {
      return {'success': false, 'message': 'Error typing text: $e'};
    }
  }

  Future<Map<String, dynamic>> pressKeys({required List<dynamic> keys}) async {
    try {
      final unvKeys = <UniversalKey>[];
      for (final key in keys) {
        final unvKey = UniversalKey.values.firstWhere((e) => e.name == key);
        unvKeys.add(unvKey);
      }
      BixatKeyMouse.simulateKeyCombination(keys: unvKeys);
      return {'success': true, 'message': 'Keys pressed: $keys', 'keys': keys};
    } catch (e) {
      return {'success': false, 'message': 'Error pressing key: $e'};
    }
  }

  Future<Map<String, dynamic>> wait({required double seconds}) async {
    await Future.delayed(Duration(milliseconds: (seconds * 1000).toInt()));
    return {'success': true, 'message': 'Waited for $seconds seconds', 'duration': seconds};
  }

  Future<Map<String, dynamic>> getShortcuts({required String query}) async {
    // MVP: not implemented. OpenRouter-based shortcut lookup replaced in later milestone.
    return {
      'success': false,
      'message': 'getShortcuts is not implemented in MVP.',
      'shortcuts': [],
      'query': query,
    };
  }

  Future<Map<String, dynamic>> askUser({required String question}) async {
    // MVP: not implemented. Headless LocalSend flow has no interactive prompt channel yet.
    return {
      'success': false,
      'message': 'askUser is not implemented in MVP.',
      'user_response': null,
      'question': question,
    };
  }

  /// Create an event in the user's macOS Calendar via AppleScript.
  ///
  /// [date] must be ISO "YYYY-MM-DD". [startTime] is 24h "HH:MM" (default "09:00").
  /// [durationMinutes] defaults to 30. If [allDay] is true, the event spans the
  /// whole calendar day and time fields are ignored. If [calendarName] is empty,
  /// the first calendar in Calendar.app is used.
  Future<Map<String, dynamic>> createCalendarEvent({
    required String title,
    required String date,
    String startTime = '09:00',
    int durationMinutes = 30,
    String notes = '',
    String calendarName = '',
    bool allDay = false,
  }) async {
    if (!Platform.isMacOS) {
      return {
        'success': false,
        'message': 'createCalendarEvent is only supported on macOS.',
      };
    }

    // Validate date — "YYYY-MM-DD".
    final dateMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date.trim());
    if (dateMatch == null) {
      return {
        'success': false,
        'message': 'date must be "YYYY-MM-DD" (got "$date").',
      };
    }
    final year = int.parse(dateMatch.group(1)!);
    final month = int.parse(dateMatch.group(2)!);
    final day = int.parse(dateMatch.group(3)!);

    // Validate start time — "HH:MM" 24h.
    int startHour = 9;
    int startMinute = 0;
    if (!allDay) {
      final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(startTime.trim());
      if (timeMatch == null) {
        return {
          'success': false,
          'message': 'startTime must be "HH:MM" 24h (got "$startTime").',
        };
      }
      startHour = int.parse(timeMatch.group(1)!);
      startMinute = int.parse(timeMatch.group(2)!);
      if (startHour < 0 || startHour > 23 || startMinute < 0 || startMinute > 59) {
        return {
          'success': false,
          'message': 'startTime out of range (got "$startTime").',
        };
      }
    }

    final durationSeconds = (durationMinutes <= 0 ? 30 : durationMinutes) * 60;

    // AppleScript reads args via `on run argv`. We pass everything as argv
    // strings (no in-script concatenation, no quoting hell).
    const script = r'''
on run argv
  set theTitle to item 1 of argv
  set theNotes to item 2 of argv
  set calName to item 3 of argv
  set yearArg to (item 4 of argv) as integer
  set monthArg to (item 5 of argv) as integer
  set dayArg to (item 6 of argv) as integer
  set hourArg to (item 7 of argv) as integer
  set minArg to (item 8 of argv) as integer
  set durSeconds to (item 9 of argv) as integer
  set allDayFlag to (item 10 of argv) as text

  -- Build the start date carefully: set day=1 first so changing month/year
  -- can't roll the date over (e.g., Jan 31 + month=Feb → Mar 3 in AppleScript).
  set theStart to current date
  set day of theStart to 1
  set hours of theStart to 0
  set minutes of theStart to 0
  set seconds of theStart to 0
  set year of theStart to yearArg
  set month of theStart to monthArg
  set day of theStart to dayArg
  if allDayFlag is not "true" then
    set hours of theStart to hourArg
    set minutes of theStart to minArg
  end if
  set theEnd to theStart + durSeconds

  tell application "Calendar"
    activate
    if calName is "" then
      set theCal to first calendar whose writable is true
    else
      try
        set theCal to first calendar whose name is calName
      on error
        set theCal to first calendar whose writable is true
      end try
    end if
    tell theCal
      if allDayFlag is "true" then
        set newEvent to make new event with properties {summary:theTitle, start date:theStart, end date:(theStart + (24 * hours)), allday event:true, description:theNotes}
      else
        set newEvent to make new event with properties {summary:theTitle, start date:theStart, end date:theEnd, description:theNotes}
      end if
      return (name of theCal) & "|" & (summary of newEvent) & "|" & ((start date of newEvent) as string)
    end tell
  end tell
end run
''';

    // Write the AppleScript to a temp file and invoke it with argv.
    try {
      final tmp = await File(
        '${Directory.systemTemp.path}/agent_mac_calendar_${DateTime.now().millisecondsSinceEpoch}.applescript',
      ).writeAsString(script);

      final result = await Process.run(
        '/usr/bin/osascript',
        [
          tmp.path,
          title,
          notes,
          calendarName,
          '$year',
          '$month',
          '$day',
          '$startHour',
          '$startMinute',
          '$durationSeconds',
          allDay ? 'true' : 'false',
        ],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      ).timeout(const Duration(seconds: 20));

      // best-effort cleanup
      try { await tmp.delete(); } catch (_) {}

      if (result.exitCode != 0) {
        return {
          'success': false,
          'message': 'osascript failed (${result.exitCode}): ${result.stderr.toString().trim()}',
        };
      }
      final out = result.stdout.toString().trim();
      return {
        'success': true,
        'message': 'Event created.',
        'detail': out,
        'title': title,
        'date': date,
        'startTime': allDay ? null : startTime,
        'durationMinutes': allDay ? null : durationMinutes,
        'allDay': allDay,
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'createCalendarEvent error: $e',
      };
    }
  }
}
