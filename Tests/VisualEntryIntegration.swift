import AppKit
import Foundation

@main
struct VisualEntryIntegration {
  @MainActor static func main() async {
    do {
      try await run()
      exit(0)
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
  static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SelectorError.message(message) }
    print("PASS \(message)")
  }
  @MainActor static func run() async throws {
    let pid = pid_t(CommandLine.arguments[1])!
    let project = URL(fileURLWithPath: CommandLine.arguments[2])
    let report = URL(fileURLWithPath: CommandLine.arguments[3])
    // Refuse to terminate any application except the explicitly disposable test host.
    guard let argv = ProcessDiscovery.arguments(for: pid),
      argv.contains(where: {
        $0.hasPrefix("--extensionDevelopmentPath=") && $0.contains("Tests/VSCodeFixture")
      }),
      let profile = argv.first(where: { $0.hasPrefix("--user-data-dir=/private/tmp/ds-visual.") })
    else { throw SelectorError.message("Refusing non-fixture process") }
    let source = try String(
      contentsOf: project.appendingPathComponent("Resources/picker.js"), encoding: .utf8)
    let capture = CaptureSession(source: source)
    let connector = ApplicationConnector(capture: capture)
    guard let candidate = connector.applications.first(where: { $0.processID == pid }) else {
      throw SelectorError.message("Disposable host not found in application inventory")
    }
    try check(
      candidate.supportsLaunch, "Electron engine detected without an application-name allowlist")
    try check(
      !candidate.windows.isEmpty, "visible target window enumerated without screenshot capture")
    await connector.select(candidate)
    try check(
      connector.state == .needsRestart && !capture.connected,
      "closed debug interface shown as needing restart; no manual port requested")
    await connector.restartConfirmed()
    guard let newPID = connector.selectedApplication?.processID else {
      throw SelectorError.message("No restarted PID")
    }
    // Always record the disposable new process so the runner can clean it up.
    let cleanup: [String: Any] = ["pid": newPID, "endpoint": capture.endpoint]
    try JSONSerialization.data(withJSONObject: cleanup).write(to: report)
    try check(
      newPID != pid && NSRunningApplication(processIdentifier: pid)?.isTerminated != false,
      "test host restarted gracefully")
    try check(
      connector.state == .ready && capture.connected,
      "restart automatically connects to the selected desktop app [\(connector.message); targets=\(capture.targets.count)]"
    )
    let newArguments = ProcessDiscovery.arguments(for: newPID) ?? []
    try check(newArguments.contains(profile), "original isolated profile preserved across restart")
    try check(
      newArguments.contains(where: {
        $0.hasPrefix("--extensionDevelopmentPath=") && $0.contains("Tests/VSCodeFixture")
      }), "original development entry preserved across restart")
    try check(
      capture.endpoint != "http://127.0.0.1:9222",
      "connection uses an automatically assigned local port")
    await capture.disconnect()
    await connector.select(connector.selectedApplication!)
    try check(
      capture.connected && connector.state == .ready,
      "already-running app reconnected by PID with no address entry or restart")
    print("AUTOMATIC_ENDPOINT \(capture.endpoint)")
    await capture.disconnect()
    print("ALL VISUAL ENTRY CHECKS PASSED")
  }
}
