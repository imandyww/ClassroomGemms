import 'dart:io';

import 'package:bixat_key_mouse/bixat_key_mouse.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:screen_capturer/screen_capturer.dart';

typedef StatusCallback = void Function(String message);
typedef ScreenshotCallback = void Function();
typedef InputAutomationInitializer = Future<void> Function();
typedef AccessibilityTrustedChecker = Future<bool> Function();
typedef AccessibilitySettingsOpener = Future<void> Function();
typedef AppRelauncher = Future<void> Function();
typedef MoveMouseCallback = void Function({required int x, required int y});
typedef PressMouseButtonCallback =
    void Function({required MouseButton button, required Direction direction});
typedef EnterTextCallback = void Function({required String text});
typedef SimulateKeyCombinationCallback =
    void Function({required List<UniversalKey> keys});

class InputAutomationStatus {
  static const String notInitializedMessage =
      'Input automation not initialized.';
  static const String accessibilityDeniedMessage =
      'Accessibility access is not active for this app yet. If you already enabled it in System Settings, quit and reopen the app, then recheck.';

  const InputAutomationStatus({
    required this.initialized,
    required this.accessibilityTrusted,
    required this.message,
    this.checkedAt,
  });

  const InputAutomationStatus.uninitialized()
    : initialized = false,
      accessibilityTrusted = false,
      message = notInitializedMessage,
      checkedAt = null;

  final bool initialized;
  final bool accessibilityTrusted;
  final String message;
  final DateTime? checkedAt;

  bool get isReady => initialized && accessibilityTrusted;
  bool get isAccessibilityBlocked =>
      initialized &&
      !accessibilityTrusted &&
      message == accessibilityDeniedMessage;
  bool get needsInitialization => !initialized;

  String get statusLabel {
    if (isReady) return 'ready';
    if (isAccessibilityBlocked) return 'blocked';
    if (initialized) return 'unavailable';
    return 'not initialized';
  }

  Map<String, dynamic> toJson() => {
    'initialized': initialized,
    'accessibilityTrusted': accessibilityTrusted,
    'message': message,
    if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
  };
}

/// macOS automation tool surface, adapted from NextDesk's AutomationService.
/// Vision-based detection, shortcut lookup, and askUser are stubbed in MVP.
class AutomationService {
  static const MethodChannel _accessibilityChannel = MethodChannel(
    'agent_mac/accessibility',
  );

  final StatusCallback onStatusUpdate;
  final ScreenshotCallback onScreenshotTaken;
  final ScreenCapturer _screenCapturer = ScreenCapturer.instance;
  final InputAutomationInitializer _inputAutomationInitializer;
  final AccessibilityTrustedChecker _accessibilityTrustedChecker;
  final AccessibilitySettingsOpener _accessibilitySettingsOpener;
  final AppRelauncher _appRelauncher;
  final MoveMouseCallback _moveMouseCallback;
  final PressMouseButtonCallback _pressMouseButtonCallback;
  final EnterTextCallback _enterTextCallback;
  final SimulateKeyCombinationCallback _simulateKeyCombinationCallback;

  Uint8List? lastScreenshot;
  InputAutomationStatus _inputAutomationStatus =
      const InputAutomationStatus.uninitialized();

  AutomationService({
    required this.onStatusUpdate,
    required this.onScreenshotTaken,
    InputAutomationInitializer? inputAutomationInitializer,
    AccessibilityTrustedChecker? accessibilityTrustedChecker,
    AccessibilitySettingsOpener? accessibilitySettingsOpener,
    AppRelauncher? appRelauncher,
    MoveMouseCallback? moveMouseCallback,
    PressMouseButtonCallback? pressMouseButtonCallback,
    EnterTextCallback? enterTextCallback,
    SimulateKeyCombinationCallback? simulateKeyCombinationCallback,
  }) : _inputAutomationInitializer =
           inputAutomationInitializer ?? _defaultInputAutomationInitializer,
       _accessibilityTrustedChecker =
           accessibilityTrustedChecker ?? _defaultAccessibilityTrustedChecker,
       _accessibilitySettingsOpener =
           accessibilitySettingsOpener ?? _defaultAccessibilitySettingsOpener,
       _appRelauncher = appRelauncher ?? _defaultAppRelauncher,
       _moveMouseCallback = moveMouseCallback ?? _defaultMoveMouse,
       _pressMouseButtonCallback =
           pressMouseButtonCallback ?? _defaultPressMouseButton,
       _enterTextCallback = enterTextCallback ?? _defaultEnterText,
       _simulateKeyCombinationCallback =
           simulateKeyCombinationCallback ?? _defaultSimulateKeyCombination;

  InputAutomationStatus get inputAutomationStatus => _inputAutomationStatus;

  Future<InputAutomationStatus> initializeInputAutomation() async {
    try {
      await _inputAutomationInitializer();
    } catch (e) {
      _inputAutomationStatus = InputAutomationStatus(
        initialized: false,
        accessibilityTrusted: false,
        message: 'Bixat init failed: $e',
        checkedAt: DateTime.now(),
      );
      onStatusUpdate(_inputAutomationStatus.message);
      return _inputAutomationStatus;
    }

    return _updateAccessibilityReadiness();
  }

  Future<InputAutomationStatus> refreshInputAutomationReadiness() async {
    if (!_inputAutomationStatus.initialized) {
      return initializeInputAutomation();
    }
    return _updateAccessibilityReadiness();
  }

  Future<InputAutomationStatus> _updateAccessibilityReadiness() async {
    try {
      final trusted = await _accessibilityTrustedChecker();
      _inputAutomationStatus = trusted
          ? InputAutomationStatus(
              initialized: true,
              accessibilityTrusted: true,
              message: 'Input automation ready.',
              checkedAt: DateTime.now(),
            )
          : InputAutomationStatus(
              initialized: true,
              accessibilityTrusted: false,
              message: InputAutomationStatus.accessibilityDeniedMessage,
              checkedAt: DateTime.now(),
            );
    } catch (e) {
      _inputAutomationStatus = InputAutomationStatus(
        initialized: true,
        accessibilityTrusted: false,
        message: 'Accessibility trust check failed: $e',
        checkedAt: DateTime.now(),
      );
    }

    onStatusUpdate(_inputAutomationStatus.message);
    return _inputAutomationStatus;
  }

  Future<void> openAccessibilitySettings() async {
    await _accessibilitySettingsOpener();
    onStatusUpdate('Opened macOS Accessibility settings.');
  }

  Future<void> relaunchApplication() async {
    await _appRelauncher();
  }

  Future<Map<String, dynamic>> captureScreenshot() async {
    late final Map<String, dynamic> result;
    try {
      final capturedImage = await _screenCapturer.capture(
        mode: CaptureMode.screen,
      );
      if (capturedImage != null) {
        final full = capturedImage.imageBytes;
        if (full != null) {
          lastScreenshot = await _resizeImage(full) ?? full;
          onScreenshotTaken();
          result = {
            'success': true,
            'message': 'Screenshot captured successfully',
            'hasImage': true,
          };
          _logToolResult('captureScreenshot', result);
          return result;
        }
      }
      result = {'success': false, 'message': 'Failed to capture screenshot'};
    } catch (e) {
      result = {'success': false, 'message': 'Error capturing screenshot: $e'};
    }
    _logToolResult('captureScreenshot', result);
    return result;
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

  Future<Map<String, dynamic>> detectElementPosition({
    required String elementDescription,
  }) async {
    final result = {
      'success': false,
      'message':
          'detectElementPosition is not implemented in MVP; use keyboard shortcuts or absolute coordinates instead.',
      'element_description': elementDescription,
    };
    _logToolResult('detectElementPosition', result);
    return result;
  }

  Map<String, dynamic> moveMouse({required int x, required int y}) {
    final blocked = _blockedInputAutomationResult('moveMouse');
    if (blocked != null) return blocked;

    late final Map<String, dynamic> result;
    try {
      _moveMouseCallback(x: x, y: y);
      result = {
        'success': true,
        'message': 'Mouse moved to ($x, $y)',
        'position': {'x': x, 'y': y},
      };
    } catch (e) {
      result = {'success': false, 'message': 'Error moving mouse: $e'};
    }
    _logToolResult('moveMouse', result);
    return result;
  }

  Map<String, dynamic> clickMouse({
    String button = 'left',
    String action = 'click',
  }) {
    final blocked = _blockedInputAutomationResult('clickMouse');
    if (blocked != null) return blocked;

    late final Map<String, dynamic> result;
    try {
      final mouseButton = switch (button.toLowerCase()) {
        'left' => MouseButton.left,
        'middle' => MouseButton.middle,
        _ => MouseButton.right,
      };
      final direction = switch (action.toLowerCase()) {
        'press' => Direction.press,
        'release' => Direction.release,
        _ => Direction.click,
      };
      _pressMouseButtonCallback(button: mouseButton, direction: direction);
      result = {
        'success': true,
        'message': 'Mouse $button button $action successful',
        'button': button,
        'action': action,
      };
    } catch (e) {
      result = {'success': false, 'message': 'Error clicking mouse: $e'};
    }
    _logToolResult('clickMouse', result);
    return result;
  }

  Map<String, dynamic> typeText({required String text}) {
    final blocked = _blockedInputAutomationResult('typeText');
    if (blocked != null) return blocked;

    late final Map<String, dynamic> result;
    try {
      _enterTextCallback(text: text);
      result = {
        'success': true,
        'message': 'Text typed successfully',
        'text': text,
      };
    } catch (e) {
      result = {'success': false, 'message': 'Error typing text: $e'};
    }
    _logToolResult('typeText', result);
    return result;
  }

  Future<Map<String, dynamic>> pressKeys({required List<dynamic> keys}) async {
    final blocked = _blockedInputAutomationResult('pressKeys');
    if (blocked != null) return blocked;

    late final Map<String, dynamic> result;
    try {
      final unvKeys = <UniversalKey>[];
      for (final key in keys) {
        final unvKey = UniversalKey.values.firstWhere(
          (candidate) => candidate.name == key,
        );
        unvKeys.add(unvKey);
      }
      _simulateKeyCombinationCallback(keys: unvKeys);
      result = {
        'success': true,
        'message': 'Keys pressed: $keys',
        'keys': keys,
      };
    } catch (e) {
      result = {'success': false, 'message': 'Error pressing key: $e'};
    }
    _logToolResult('pressKeys', result);
    return result;
  }

  Future<Map<String, dynamic>> wait({required double seconds}) async {
    await Future.delayed(Duration(milliseconds: (seconds * 1000).toInt()));
    final result = {
      'success': true,
      'message': 'Waited for $seconds seconds',
      'duration': seconds,
    };
    _logToolResult('wait', result);
    return result;
  }

  Future<Map<String, dynamic>> getShortcuts({required String query}) async {
    final result = {
      'success': false,
      'message': 'getShortcuts is not implemented in MVP.',
      'shortcuts': [],
      'query': query,
    };
    _logToolResult('getShortcuts', result);
    return result;
  }

  Future<Map<String, dynamic>> askUser({required String question}) async {
    final result = {
      'success': false,
      'message': 'askUser is not implemented in MVP.',
      'user_response': null,
      'question': question,
    };
    _logToolResult('askUser', result);
    return result;
  }

  /// Create an event in the user's macOS Calendar via AppleScript.
  ///
  /// [date] must be ISO "YYYY-MM-DD". [startTime] is 24h "HH:MM" (default
  /// "09:00"). [durationMinutes] defaults to 30. If [allDay] is true, the
  /// event spans the whole calendar day and time fields are ignored. If
  /// [calendarName] is empty, the first calendar in Calendar.app is used.
  Future<Map<String, dynamic>> createCalendarEvent({
    required String title,
    required String date,
    String startTime = '09:00',
    int durationMinutes = 30,
    String notes = '',
    String calendarName = '',
    bool allDay = false,
  }) async {
    late final Map<String, dynamic> result;
    if (!Platform.isMacOS) {
      result = {
        'success': false,
        'message': 'createCalendarEvent is only supported on macOS.',
      };
      _logToolResult('createCalendarEvent', result);
      return result;
    }

    final dateMatch = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})$',
    ).firstMatch(date.trim());
    if (dateMatch == null) {
      result = {
        'success': false,
        'message': 'date must be "YYYY-MM-DD" (got "$date").',
      };
      _logToolResult('createCalendarEvent', result);
      return result;
    }
    final year = int.parse(dateMatch.group(1)!);
    final month = int.parse(dateMatch.group(2)!);
    final day = int.parse(dateMatch.group(3)!);

    int startHour = 9;
    int startMinute = 0;
    if (!allDay) {
      final timeMatch = RegExp(
        r'^(\d{1,2}):(\d{2})$',
      ).firstMatch(startTime.trim());
      if (timeMatch == null) {
        result = {
          'success': false,
          'message': 'startTime must be "HH:MM" 24h (got "$startTime").',
        };
        _logToolResult('createCalendarEvent', result);
        return result;
      }
      startHour = int.parse(timeMatch.group(1)!);
      startMinute = int.parse(timeMatch.group(2)!);
      if (startHour < 0 ||
          startHour > 23 ||
          startMinute < 0 ||
          startMinute > 59) {
        result = {
          'success': false,
          'message': 'startTime out of range (got "$startTime").',
        };
        _logToolResult('createCalendarEvent', result);
        return result;
      }
    }

    final durationSeconds = (durationMinutes <= 0 ? 30 : durationMinutes) * 60;

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

    try {
      final tmp = await File(
        '${Directory.systemTemp.path}/agent_mac_calendar_${DateTime.now().millisecondsSinceEpoch}.applescript',
      ).writeAsString(script);

      final osascriptResult = await Process.run(
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

      try {
        await tmp.delete();
      } catch (_) {}

      if (osascriptResult.exitCode != 0) {
        result = {
          'success': false,
          'message':
              'osascript failed (${osascriptResult.exitCode}): ${osascriptResult.stderr.toString().trim()}',
        };
        _logToolResult('createCalendarEvent', result);
        return result;
      }
      final out = osascriptResult.stdout.toString().trim();
      result = {
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
      result = {'success': false, 'message': 'createCalendarEvent error: $e'};
    }
    _logToolResult('createCalendarEvent', result);
    return result;
  }

  Map<String, dynamic>? _blockedInputAutomationResult(String toolName) {
    if (_inputAutomationStatus.isReady) return null;
    final errorCode = _inputAutomationStatus.isAccessibilityBlocked
        ? 'accessibility_denied'
        : _inputAutomationStatus.needsInitialization
        ? 'input_automation_not_initialized'
        : 'input_automation_unavailable';
    final result = {
      'success': false,
      'message': _inputAutomationStatus.message,
      'errorCode': errorCode,
      'readiness': _inputAutomationStatus.toJson(),
    };
    _logToolResult(toolName, result);
    return result;
  }

  void _logToolResult(String toolName, Map<String, dynamic> result) {
    final state = result['success'] == true ? 'ok' : 'failed';
    final message = (result['message'] ?? '').toString();
    onStatusUpdate('$toolName $state${message.isEmpty ? '' : ': $message'}');
  }

  static Future<void> _defaultInputAutomationInitializer() async {
    await BixatKeyMouse.initialize();
  }

  static Future<bool> _defaultAccessibilityTrustedChecker() async {
    if (!Platform.isMacOS) return true;
    final trusted = await _accessibilityChannel.invokeMethod<bool>('isTrusted');
    return trusted ?? false;
  }

  static Future<void> _defaultAccessibilitySettingsOpener() async {
    if (!Platform.isMacOS) return;
    final opened = await _accessibilityChannel.invokeMethod<bool>(
      'openSettings',
    );
    if (opened != true) {
      throw Exception('Unable to open macOS Accessibility settings.');
    }
  }

  static Future<void> _defaultAppRelauncher() async {
    if (!Platform.isMacOS) return;
    final relaunched = await _accessibilityChannel.invokeMethod<bool>(
      'relaunch',
    );
    if (relaunched != true) {
      throw Exception('Unable to relaunch the app.');
    }
  }

  static void _defaultMoveMouse({required int x, required int y}) {
    BixatKeyMouse.moveMouse(x: x, y: y);
  }

  static void _defaultPressMouseButton({
    required MouseButton button,
    required Direction direction,
  }) {
    BixatKeyMouse.pressMouseButton(button: button, direction: direction);
  }

  static void _defaultEnterText({required String text}) {
    BixatKeyMouse.enterText(text: text);
  }

  static void _defaultSimulateKeyCombination({
    required List<UniversalKey> keys,
  }) {
    BixatKeyMouse.simulateKeyCombination(keys: keys);
  }
}
