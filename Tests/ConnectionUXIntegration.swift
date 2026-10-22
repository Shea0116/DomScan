import AppKit
import Foundation

@main
struct ConnectionUXIntegration {
  @MainActor static func main() async {
    do {
      try await run()
      print("ALL CONNECTION UX CHECKS PASSED")
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

  static func element(_ id: String, window: String, note: String) -> SelectedElement {
    SelectedElement(id: id,
      world: ExecutionWorld(sessionID: "fixture", contextID: 1, uniqueID: id, frameID: "frame"),
      frameURL: "https://fixture.local/\(id)", frameTitle: window, capturedFramePath: [],
      windowTitle: window, windowURL: "https://fixture.local/\(id)",
      snapshot: ["token": id, "tag": "button", "name": id, "html": "<button>\(id)</button>"], note: note)
  }

  @MainActor static func run() async throws {
    let capture = CaptureSession(source: "")
    let connector = ApplicationConnector(capture: capture)
    let unknown = DesktopApplication(processID: nil, name: "Unknown App",
      bundleURL: URL(fileURLWithPath: "/private/tmp/Unknown.app"), icon: nil,
      supportsLaunch: false, windows: [])
    let chromium = DesktopApplication(processID: nil, name: "Chromium Fixture",
      bundleURL: URL(fileURLWithPath: "/private/tmp/ChromiumFixture.app"), icon: nil,
      supportsLaunch: true, windows: [])

    capture.applicationName = "Original App"
    capture.elements = [element("original", window: "Original Window", note: "保留这条备注")]
    await connector.select(unknown)
    try check(!capture.connected && connector.connectionLabel == "窗口已选中 · HTML 未连接",
      "selected window is explicitly distinct from an HTML connection")
    try check(connector.state == .unsupported && !connector.offersRetry
      && !connector.offersInspectionInstance && connector.offersBridgeGuide,
      "missing interface offers setup guidance instead of an ineffective retry")
    try check(connector.capability(for: unknown) == .unknown,
      "unknown application is not classified as definitively unsupported")
    try check(connector.diagnosticSteps.count == 4
      && connector.diagnosticSteps[0].status == .success && connector.diagnosticSteps[1].status == .failed
      && connector.diagnosticSteps[2].status == .pending,
      "diagnostics identify interface discovery as the failing stage without claiming page attachment")
    capture.endpoint = "http://127.0.0.1:9999/private?token=DO_NOT_COPY"
    capture.error = "DO_NOT_COPY"
    let diagnostics = connector.diagnosticReport()
    try check(!diagnostics.contains("DO_NOT_COPY") && !diagnostics.contains("保留这条备注")
      && !diagnostics.contains("Local endpoint:"),
      "diagnostics exclude captured contents, stale endpoints, URL query secrets and unrelated errors")
    capture.error = nil
    try check(capture.elements.isEmpty && capture.reviewingArchive == nil && capture.archives.count == 1,
      "switching application archives old elements and defaults to the current target")

    let archiveID = capture.archives[0].id
    capture.reviewArchive(archiveID)
    try check(capture.displayedApplicationName == "Original App"
      && capture.displayedElements[0].note == "保留这条备注" && capture.displayedElements[0].stale,
      "archive preserves application, window, note, and static capture state")
    capture.note("original", "历史备注可以继续编辑")
    let exported = try JSONSerialization.jsonObject(with: capture.exportJSON()) as! [String: Any]
    try check(exported["application"] as? String == "Original App"
      && (exported["target"] as? [String: String])?["title"] == "Original Window"
      && capture.exportMarkdown().contains("历史备注可以继续编辑")
      && !capture.exportMarkdown().contains("Unknown App"),
      "historical export uses its own source and edited notes, not the newly selected application")

    await connector.select(chromium)
    try check(connector.state == .needsRestart && connector.offersInspectionInstance
      && !connector.offersRetry && !connector.offersBridgeGuide,
      "Chromium without a debug interface recommends an inspection instance")
    try check(connector.capability(for: chromium) == .chromium
      && ConnectionCapability.bridge.rawValue < ConnectionCapability.chromium.rawValue
      && ConnectionCapability.chromium.rawValue < ConnectionCapability.unknown.rawValue,
      "bridge and engine evidence take priority over unknown applications")
    try check(capture.reviewingArchive == nil && capture.archives.count == 1,
      "empty switches do not overwrite history and leave historical review")

    capture.elements = [element("current", window: "Current Window", note: "当前备注")]
    capture.reviewArchive(archiveID)
    capture.remove("original")
    try check(capture.archives.isEmpty && capture.displayedElements.first?.id == "current"
      && capture.elements.first?.note == "当前备注",
      "removing the last archived element returns to current capture without deleting current notes")

    capture.archiveCurrentCapture()
    capture.elements = [element("next", window: "Next Window", note: "新备注")]
    capture.reviewArchive(capture.archives[0].id)
    capture.clear()
    try check(capture.archives.isEmpty && capture.elements.first?.id == "next",
      "deleting a historical group does not clear current selection")
    capture.archiveCurrentCapture()
    capture.elements = [element("third", window: "Third Window", note: "第三条")]
    capture.archiveCurrentCapture()
    try check(capture.archives.count == 2 && capture.archives[1].elements[0].note == "新备注",
      "multiple switches preserve earlier groups and their notes")

    connector.state = .failed
    try check(connector.offersRetry && !connector.offersInspectionInstance,
      "temporary failures offer retry without immediately recommending a new instance")
    connector.state = .ready
    capture.targets = []
    try check(!connector.offersRetry && connector.guidanceMessage.contains("没有可选择的 HTML 页面"),
      "an interface with no pages prompts the user to open a page")
    capture.connected = true
    try check(connector.connectionLabel == "HTML 已连接" && !connector.offersRetry,
      "connected state enables an unambiguous successful connection label")
    capture.connected = false
    await capture.disconnect()
    try await checkNativeExports()
  }

  @MainActor static func checkNativeExports() async throws {
    let capture = CaptureSession(source: "")
    capture.applicationName = "Native Fixture"
    capture.addNativeCapture([
      "captureSource": "accessibility", "tag": "AXButton", "name": "确认",
      "selector": "confirm-button", "attributes": ["AXRole": "AXButton", "AXIdentifier": "confirm-button"],
      "bounds": ["x": -900, "y": 80, "width": 120, "height": 40],
      "limitations": "辅助功能元数据，不包含 DOM、CSS 或输入框当前值。"
    ], windowTitle: "Native Window")
    try check(capture.elements[0].source == .accessibility && capture.elements[0].kindLabel == "AXButton",
      "native controls carry explicit accessibility provenance instead of an HTML tag")
    capture.note(capture.elements[0].id, "原生按钮备注")
    let markdown = capture.exportMarkdown()
    try check(markdown.contains("macOS 辅助功能") && markdown.contains("原生按钮备注")
      && markdown.contains("global screen points") && !markdown.contains("Computed CSS:")
      && !markdown.contains("Frame URL:") && !markdown.contains("HTML (truncated"),
      "native exports distinguish global coordinates and never invent DOM, CSS or frame metadata")

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    capture.addNativeCapture(["captureSource": "screenshot", "tag": "region", "name": "框选截图",
      "imagePNGBase64": png.base64EncodedString(), "bounds": ["x": 10, "y": 20, "width": 8, "height": 8],
      "limitations": "区域截图，不包含 DOM、CSS、OCR 或源码映射。"], windowTitle: "Native Window")
    try check(capture.elements[1].imagePNG == png && capture.exportMarkdown().contains("data:image/png;base64,")
      && !capture.exportMarkdown(includeImages: false).contains(png.base64EncodedString()),
      "screenshot exports retain a valid PNG while preview avoids rendering base64 text")
    let json = try JSONSerialization.jsonObject(with: capture.exportJSON()) as! [String: Any]
    let rows = json["elements"] as! [[String: Any]]
    try check(rows[0]["source"] as? String == "accessibility" && rows[1]["source"] as? String == "screenshot"
      && ((rows[1]["element"] as? [String: Any])?["imagePNGBase64"] as? String) == png.base64EncodedString(),
      "JSON preserves each source and embeds the screenshot for a self-contained export")
    await capture.disconnect()
    try check(capture.elements.allSatisfy { !$0.stale },
      "disconnecting HTML does not invalidate static accessibility or screenshot captures")
    capture.archiveCurrentCapture()
    capture.reviewArchive(capture.archives[0].id)
    try check(capture.displayedElements[0].note == "原生按钮备注" && capture.displayedElements[1].imagePNG == png,
      "native history retains editable notes and original image bytes")
  }
}
