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
}
