import Cocoa
import ApplicationServices
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var accessibilityChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    accessibilityChannel = FlutterMethodChannel(
      name: "agent_mac/accessibility",
      binaryMessenger: controller.engine.binaryMessenger
    )
    accessibilityChannel?.setMethodCallHandler(handleAccessibilityCall)
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func handleAccessibilityCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isTrusted":
      result(AXIsProcessTrusted())
    case "openSettings":
      if !AXIsProcessTrusted() {
        let options = [
          kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
      }
      guard let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      ) else {
        result(
          FlutterError(
            code: "invalid_url",
            message: "Unable to build Accessibility settings URL.",
            details: nil
          )
        )
        return
      }
      result(NSWorkspace.shared.open(url))
    case "relaunch":
      let appURL = Bundle.main.bundleURL
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
        if let error {
          result(
            FlutterError(
              code: "relaunch_failed",
              message: "Unable to relaunch the app.",
              details: error.localizedDescription
            )
          )
          return
        }
        result(true)
        // Accessibility changes commonly apply on the next launch, not to the
        // running process that requested them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          NSApp.terminate(nil)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
