import AppKit
import Foundation

@main struct EngineEntryIntegration {
  @MainActor static func main() async {
    do {
      try checkDetection()
      let pid = pid_t(CommandLine.arguments[1])!
      let project = URL(fileURLWithPath: CommandLine.arguments[2])
      guard let argv = ProcessDiscovery.arguments(for: pid),
        argv.contains(where: { $0.hasPrefix("--user-data-dir=/private/tmp/ds-engine.") })
      else { throw SelectorError.message("Refusing non-fixture process") }
      let capture = CaptureSession(source: try String(
        contentsOf: project.appendingPathComponent("Resources/picker.js"), encoding: .utf8))
      let connector = ApplicationConnector(capture: capture)
      guard let app = connector.applications.first(where: { $0.processID == pid }) else {
        throw SelectorError.message("Isolated app not in inventory")
      }
      guard app.supportsLaunch else { throw SelectorError.message("Renamed Chromium not detected") }
      print("PASS renamed Chromium framework detected by resource layout")
      await connector.select(app, windowTitle: "Selector Fixture · Desktop")
      guard capture.connected, connector.state == .ready else {
        throw SelectorError.message("Automatic attach failed: \(connector.message)")
      }
      print("PASS isolated desktop instance discovered by owning PID without entering a port")
      guard capture.selectedTarget?.title == "Selector Fixture · Desktop" else {
        throw SelectorError.message("Selected unrelated page")
      }
      print("PASS selected desktop window matched to HTML target")
      for _ in 0..<100 {
        if capture.worlds.count >= 4 { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard capture.worlds.count >= 4 else {
        for world in capture.worlds.values {
          let result = try? await capture.cdp.request("Runtime.evaluate", [
            "expression": "({protocol:location.protocol,path:location.pathname,fixture:!!document.querySelector('#primary'),frameCount:document.querySelectorAll('iframe').length})",
            "uniqueContextId": world.uniqueID,"returnByValue":true], sessionID:world.sessionID)
          print("WORLD DIAGNOSTIC \(result?["result"] ?? [:])")
        }
        throw SelectorError.message("Missing iframe worlds: \(capture.worlds.count); \(capture.frameWarnings)")
      }
      print("PASS real HTML and iframe execution contexts ready")
      guard let rootWorld = capture.worlds.values.first(where: { capture.framePath($0.frameID).count == 1 }) else {
        throw SelectorError.message("No root execution context")
      }
      try await capture.evaluate("document.title='Selector Fixture · Updated';", world: rootWorld)
      for _ in 0..<50 {
        if capture.selectedTarget?.title == "Selector Fixture · Updated" { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      guard capture.selectedTarget?.title == "Selector Fixture · Updated",
        capture.targets.contains(where: { $0.title == "Selector Fixture · Updated" }) else {
        throw SelectorError.message("Target metadata did not refresh")
      }
      print("PASS target list and selected window title refresh after startup/navigation")
      try await capture.evaluate("document.title='Selector Fixture · Desktop';", world: rootWorld)
      await capture.disconnect()
      print("ALL RENAMED ENGINE ENTRY CHECKS PASSED")
      exit(0)
    } catch { print("FAIL \(error)"); exit(1) }
  }

  static func checkDetection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "selector-engine-detection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Contents/Frameworks/Random Brand.framework/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    guard !DesktopApplication.hasChromiumEngine(root) else {
      throw SelectorError.message("Empty framework incorrectly detected as Chromium")
    }
    for name in ["icudtl.dat", "resources.pak"] { try Data().write(to: resources.appendingPathComponent(name)) }
    guard !DesktopApplication.hasChromiumEngine(root) else {
      throw SelectorError.message("Partial generic resources incorrectly detected as Chromium")
    }
    try Data().write(to: resources.appendingPathComponent("chrome_200_percent.pak"))
    guard DesktopApplication.hasChromiumEngine(root) else {
      throw SelectorError.message("Arbitrarily renamed framework not detected")
    }
    print("PASS generic resource fingerprint accepts renamed engines and rejects partial matches")
    guard DebugTarget(["id":"loading","type":"page","url":"about:blank"])?.isPlaceholder == true,
      DebugTarget(["id":"ready","type":"page","url":"app://local/index.html"])?.isPlaceholder == false else {
      throw SelectorError.message("Startup placeholder classification failed")
    }
    print("PASS blank startup pages excluded from automatic connection")
  }
}
