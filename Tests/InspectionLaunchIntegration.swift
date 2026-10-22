import AppKit
import Foundation

@main struct InspectionLaunchIntegration {
  @MainActor static func main() async {
    do {
      let pid = pid_t(CommandLine.arguments[1])!
      let project = URL(fileURLWithPath: CommandLine.arguments[2])
      let root = URL(fileURLWithPath: CommandLine.arguments[3])
      let report = URL(fileURLWithPath: CommandLine.arguments[4])
      guard root.path.hasPrefix("/private/tmp/ds-launch."),
        let argv = ProcessDiscovery.arguments(for: pid),
        argv.contains(where: { $0.hasPrefix("--user-data-dir=/private/tmp/ds-engine.") })
      else { throw SelectorError.message("Refusing non-fixture process/profile") }
      let capture = CaptureSession(source: try String(
        contentsOf: project.appendingPathComponent("Resources/picker.js"), encoding: .utf8))
      let connector = ApplicationConnector(capture: capture, inspectionRoot: root)
      guard let original = connector.applications.first(where: { $0.processID == pid }) else {
        throw SelectorError.message("Original fixture not found")
      }
      await connector.select(original)
      await connector.openInspectionInstance()
      if let launched = connector.selectedApplication?.processID, launched != pid {
        let info: [String: Any] = ["pid": launched, "profile": connector.inspectionProfile?.path ?? ""]
        try JSONSerialization.data(withJSONObject: info).write(to: report)
      }
      guard let newPID = connector.selectedApplication?.processID, newPID != pid,
        NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
        throw SelectorError.message("Independent launch did not preserve original instance")
      }
      print("PASS independent inspection instance opens without closing original app")
      guard let newArgs = ProcessDiscovery.arguments(for: newPID),
        newArgs.contains(where: { $0.hasPrefix("--user-data-dir=" + root.path + "/") }),
        newArgs.contains("--remote-debugging-address=127.0.0.1") else {
        throw SelectorError.message("New instance not using dedicated profile / loopback address")
      }
      print("PASS separate webpage profile and loopback debugging arguments applied")
      guard connector.state == .ready, !capture.targets.isEmpty else {
        throw SelectorError.message("Independent instance HTML not ready: \(connector.message)")
      }
      guard capture.selectedTarget?.isPlaceholder != true,
        capture.targets.contains(where: { !$0.isPlaceholder }) else {
        throw SelectorError.message("Connected to startup placeholder")
      }
      print("PASS new instance exposes real HTML targets without manual port entry")
      await capture.disconnect()
      await connector.select(original)
      await connector.openInspectionInstance()
      guard connector.selectedApplication?.processID == newPID else {
        throw SelectorError.message("Existing inspection instance was not reused")
      }
      print("PASS repeated request reuses existing inspection instance")
      await capture.disconnect()
      print("ALL INDEPENDENT LAUNCH CHECKS PASSED")
      exit(0)
    } catch { print("FAIL \(error)"); exit(1) }
  }
}
