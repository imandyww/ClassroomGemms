import 'package:automation_core/automation_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AutomationService input readiness', () {
    test(
      'reports ready and allows key presses after successful initialization',
      () async {
        final logs = <String>[];
        final pressedKeyNames = <String>[];
        final service = AutomationService(
          onStatusUpdate: logs.add,
          onScreenshotTaken: () {},
          inputAutomationInitializer: () async {},
          accessibilityTrustedChecker: () async => true,
          simulateKeyCombinationCallback: ({required keys}) {
            pressedKeyNames.addAll(keys.map((key) => key.name));
          },
        );

        final status = await service.initializeInputAutomation();
        final result = await service.pressKeys(
          keys: const ['leftCommand', 'space'],
        );

        expect(status.isReady, isTrue);
        expect(service.inputAutomationStatus.isReady, isTrue);
        expect(result['success'], isTrue);
        expect(pressedKeyNames, ['leftCommand', 'space']);
        expect(logs, contains('Input automation ready.'));
      },
    );

    test(
      'blocks input actions when accessibility permission is missing',
      () async {
        final logs = <String>[];
        final service = AutomationService(
          onStatusUpdate: logs.add,
          onScreenshotTaken: () {},
          inputAutomationInitializer: () async {},
          accessibilityTrustedChecker: () async => false,
          simulateKeyCombinationCallback: ({required keys}) {
            fail('pressKeys should not run when accessibility is blocked.');
          },
        );

        await service.initializeInputAutomation();
        final result = await service.pressKeys(
          keys: const ['leftCommand', 'space'],
        );

        expect(service.inputAutomationStatus.isAccessibilityBlocked, isTrue);
        expect(result['success'], isFalse);
        expect(
          result['message'],
          InputAutomationStatus.accessibilityDeniedMessage,
        );
        expect(result['errorCode'], 'accessibility_denied');
        expect(
          logs,
          contains(InputAutomationStatus.accessibilityDeniedMessage),
        );
      },
    );

    test('surfaces init failures and keeps input actions gated', () async {
      final logs = <String>[];
      final service = AutomationService(
        onStatusUpdate: logs.add,
        onScreenshotTaken: () {},
        inputAutomationInitializer: () async {
          throw Exception('boom');
        },
        accessibilityTrustedChecker: () async => true,
        enterTextCallback: ({required text}) {
          fail('typeText should not run after init failure.');
        },
      );

      await service.initializeInputAutomation();
      final result = service.typeText(text: 'hello');

      expect(service.inputAutomationStatus.initialized, isFalse);
      expect(result['success'], isFalse);
      expect(result['errorCode'], 'input_automation_not_initialized');
      expect(result['message'], contains('Bixat init failed: Exception: boom'));
      expect(logs.last, contains('typeText failed:'));
    });

    test('can delegate an app relaunch through the injected bridge', () async {
      var didRelaunch = false;
      final service = AutomationService(
        onStatusUpdate: (_) {},
        onScreenshotTaken: () {},
        appRelauncher: () async {
          didRelaunch = true;
        },
      );

      await service.relaunchApplication();

      expect(didRelaunch, isTrue);
    });
  });
}
