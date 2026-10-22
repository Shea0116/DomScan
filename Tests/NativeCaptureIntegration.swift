import AppKit
import ApplicationServices

@MainActor
final class NativeFixtureDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var button: NSButton!
  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(contentRect: CGRect(x: 180, y: 180, width: 600, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Native Capture Fixture"
    window.isReleasedWhenClosed = false
    let content = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.systemIndigo.cgColor
    button = NSButton(title: "Native Confirm", target: nil, action: nil)
    button.frame = CGRect(x: 40, y: 170, width: 180, height: 40)
    button.bezelStyle = .rounded
    button.setAccessibilityIdentifier("native-confirm")
    content.addSubview(button)
    let field = NSSecureTextField(frame: CGRect(x: 40, y: 90, width: 240, height: 30))
    field.stringValue = "DO_NOT_CAPTURE_INPUT_VALUE"
    field.placeholderString = "Secure input must not be collected"
    content.addSubview(field)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if !CommandLine.arguments.contains("--serve") {
      Task {
        do { try await run(); print("ALL NATIVE CAPTURE CHECKS PASSED"); exit(0) }
        catch { print("FAIL \(error)"); exit(1) }
      }
    }
  }
  func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SelectorError.message(message) }
    print("PASS \(message)")
  }
  func run() async throws {
    let bounds = CGRect(x: -1000, y: 100, width: 800, height: 600)
    let region = DesktopSelection.clippedRegion(from: CGPoint(x: -250, y: 500),
      to: CGPoint(x: -1200, y: 50), within: bounds)
    try check(region == CGRect(x: -1000, y: 100, width: 750, height: 400),
      "reverse drag and negative display coordinates stay clipped to the selected window")
    let pid = ProcessInfo.processInfo.processIdentifier
    let top = NSScreen.screens.first!.frame.maxY
    let buttonRect = window.convertToScreen(button.frame)
    let point = CGPoint(x: buttonRect.midX, y: top - buttonRect.midY)
    if AXIsProcessTrusted() {
      let snapshot = try NativeCapture.accessibilitySnapshot(at: point, pid: pid)
      try check(snapshot["captureSource"] as? String == "accessibility"
        && (snapshot["attributes"] as? [String: String])?[kAXIdentifierAttribute] == "native-confirm",
        "real AppKit button hit test returns native accessibility metadata")
      try check(!CaptureSession.jsonString(snapshot).contains("DO_NOT_CAPTURE_INPUT_VALUE"),
        "accessibility snapshot excludes input values")
    } else {
      do {
        _ = try NativeCapture.accessibilitySnapshot(at: point, pid: pid)
        throw SelectorError.message("unexpected accessibility permission bypass")
      } catch {
        try check(error.localizedDescription.contains("需要辅助功能权限"),
          "missing accessibility permission returns an actionable error without reading controls")
      }
      print("SKIP real AX metadata: system accessibility permission is not granted to the test host")
    }
    let frame = window.frame
    let screenBounds = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    let selection = DesktopSelection(window: DesktopWindow(id: window.windowNumber, processID: pid,
      title: window.title, owner: "NativeFixture", bounds: screenBounds), point: point,
      region: CGRect(x: screenBounds.minX + 300, y: screenBounds.minY + 100, width: 100, height: 100))
    if CGPreflightScreenCaptureAccess() {
      let snapshot = try await NativeCapture.screenshot(selection)
      let data = Data(base64Encoded: snapshot["imagePNGBase64"] as! String)!
      let bitmap = NSBitmapImageRep(data: data)!
      try check(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 200,
        "real ScreenCaptureKit region capture produces the requested PNG pixel dimensions")
      let color = bitmap.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB)
      try check(color != nil && color!.blueComponent > color!.redComponent,
        "captured pixels belong to the selected indigo window region")
    } else {
      do {
        _ = try await NativeCapture.screenshot(selection)
        throw SelectorError.message("unexpected screen permission bypass")
      } catch {
        try check(error.localizedDescription.contains("需要屏幕录制权限"),
          "missing screen recording permission prevents screenshot access with a clear error")
      }
      print("SKIP real screenshot pixels: screen recording permission is not granted to the test host")
    }
  }
}

@main struct NativeCaptureIntegration {
  static func main() {
    let application = NSApplication.shared
    let delegate = NativeFixtureDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
  }
}
