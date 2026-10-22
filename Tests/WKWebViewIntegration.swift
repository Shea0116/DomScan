import AppKit
import WebKit

@MainActor
final class FrameProbe: NSObject, WKScriptMessageHandler {
  var frames: [String: WKFrameInfo] = [:]
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if let path = message.body as? String { frames[path] = message.frameInfo }
  }
}

@main
struct WKWebViewIntegration {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let probe = FrameProbe()
    let config = WKWebViewConfiguration()
    config.userContentController.add(probe, name: "fixtureProbe")
    config.userContentController.addUserScript(WKUserScript(
      source: "window.webkit.messageHandlers.fixtureProbe.postMessage(location.pathname)",
      injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 800), configuration: config)
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "DomScan WKWebView Fixture"
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    if !CommandLine.arguments.contains("--observe") { DomScanBridge.shared.attach(to: view) }
    view.load(URLRequest(url: URL(string: "http://127.0.0.1:9471/")!))
    if !CommandLine.arguments.contains("--serve") {
      Task { @MainActor in
        do { try await run(view, probe); DomScanBridge.shared.stop(); exit(0) }
        catch { print("FAIL \(error)"); DomScanBridge.shared.stop(); exit(1) }
      }
    }
    app.run()
  }

  static func check(_ value: Bool, _ label: String) throws {
    guard value else { throw SelectorError.message(label) }
    print("PASS \(label)")
  }
  @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw SelectorError.message("Timeout: \(label)")
  }
  @MainActor static func js(_ view: WKWebView, _ probe: FrameProbe, _ path: String, _ script: String) async throws -> Any? {
    guard let frame = probe.frames[path] else { throw SelectorError.message("No fixture frame \(path)") }
    return try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript(script, in: frame, in: .page) { continuation.resume(with: $0) }
    }
  }
  @MainActor static func run(_ view: WKWebView, _ probe: FrameProbe) async throws {
    try await wait("WKWebView frames load") { probe.frames["/nested.html"] != nil }
    if CommandLine.arguments.contains("--observe") {
      DomScanBridge.shared.start()
      try await Task.sleep(nanoseconds: 700_000_000)
      probe.frames = [:]
      view.reload()
      try await wait("observed frames after reload") { probe.frames["/nested.html"] != nil }
      try check(true, "window observer discovers already loaded WKWebView and covers frames after reload")
    }
    let pid = ProcessInfo.processInfo.processIdentifier
    var endpoint: WebKitEndpoint?
    try await wait("private manifest") {
      endpoint = WebKitEndpoint.find(pid: pid, bundleURL: Bundle.main.bundleURL)
      return endpoint != nil
    }
    try check(endpoint != nil, "automatic PID discovery without a port argument")
    let bad = WebKitConnection()
    do {
      try await bad.open(WebKitEndpoint(pid: pid, port: endpoint!.port, token: String(repeating: "x", count: 72)))
      throw SelectorError.message("invalid credential accepted")
    } catch { try check(error.localizedDescription != "invalid credential accepted", "invalid bridge credential rejected") }
    bad.close()
    let store = CaptureSession(source: "unused by WebKit")
    try await store.discoverWebKit(endpoint!)
    guard let target = store.targets.first else { throw SelectorError.message("missing WK target") }
    try check(!target.needsReload, "complete first-load frame injection does not request another reload")
    await store.connect(target)
    try check(store.connected && store.isWebKit, "connected to real WKWebView")
    try await wait("four real frames") { store.worlds.count == 4 }
    try check(true, "main, same-origin, cross-origin and nested WK frames attached")
    let isolated = try await js(view, probe, "/", "typeof globalThis.__desktopSelector") as? String
    try check(isolated == "undefined", "bridge globals isolated from application JavaScript")
    await store.setPicking(true)
    _ = try await js(view, probe, "/", "document.querySelector('#primary').click()")
    try await wait("main capture") { store.elements.count == 1 }
    try check(store.elements[0].selector.contains("save-button") && store.elements[0].snapshot["styles"] is [String: String], "real HTML selector, CSS and geometry captured")
    let count = try await js(view, probe, "/", "window.clickCount") as? Int
    try check(count == 0, "picking suppresses application click handler")
    for path in ["/cross.html", "/nested.html"] {
      _ = try await js(view, probe, path, "document.querySelector('#frame-button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}))")
    }
    try await wait("nested captures") { store.elements.count == 3 }
    try check(store.elements.contains { $0.frameURL.contains("nested.html") }, "cross-origin and nested iframe HTML captured with independent identity")
    _ = try await js(view, probe, "/", "document.querySelector('#shadow-host').shadowRoot.querySelector('button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}))")
    try await wait("shadow capture") { store.elements.count == 4 }
    try check((store.elements.last?.snapshot["shadowPath"] as? [String])?.count == 2, "WK open Shadow DOM captured")
    store.note(store.elements[0].id, "WK test note")
    try check(store.exportMarkdown().contains("WK test note") && store.exportMarkdown().contains("nested.html"), "WK Markdown export includes notes, HTML and frame URLs")
    let exported = try JSONSerialization.jsonObject(with: store.exportJSON()) as? [String: Any]
    try check((exported?["elements"] as? [Any])?.count == 4, "WK JSON export contains all captures")
    let before = store.worlds.count
    _ = try await js(view, probe, "/", "(()=>{const f=document.createElement('iframe');f.id='dynamic';f.src='http://localhost:9472/dynamic.html';document.body.append(f)})()")
    try await wait("dynamic WK frame") { store.worlds.count > before && probe.frames["/dynamic.html"] != nil }
    _ = try await js(view, probe, "/dynamic.html", "document.querySelector('#frame-button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}))")
    try await wait("dynamic frame active") { store.elements.count == 5 }
    try check(true, "new cross-origin iframe inherits active picking")
    _ = try await js(view, probe, "/cross.html", "window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
    try await wait("WK Escape") { !store.picking }
    try await Task.sleep(nanoseconds: 200_000_000)
    let after = try await js(view, probe, "/", "document.querySelector('#primary').click(); window.clickCount") as? Int
    try check(after == 1, "Escape in a child frame restores normal main-frame click")
    let old = store.elements[0]
    await store.navigate(old, direction: "parent")
    try await wait("navigate parent") { store.elements.count == 1 && store.elements[0].tag == "section" }
    _ = try await js(view, probe, "/", "document.querySelector('#main-card').setAttribute('data-refreshed','yes')")
    await store.refresh()
    try await wait("refresh") { (store.elements[0].snapshot["html"] as? String)?.contains("data-refreshed") == true }
    try check(true, "WK parent navigation and snapshot refresh work")
    await store.setPicking(true)
    _ = try await js(view, probe, "/nested.html", "document.querySelector('#frame-button').click()")
    try await wait("nested selection") { store.elements.first?.frameURL.contains("nested.html") == true }
    _ = try await js(view, probe, "/", "document.querySelector('#cross').remove()")
    try await wait("removed WK frame") { store.elements.first?.stale == true }
    try check(true, "removed nested frame retains capture and becomes stale")
    // Abrupt socket loss must release all input without waiting for a clean detach.
    store.webkit.close()
    try await Task.sleep(nanoseconds: 300_000_000)
    let disconnectedCount = try await js(view, probe, "/", "document.querySelector('#primary').click(); window.clickCount") as? Int
    try check(disconnectedCount == 2, "abrupt socket close releases page click interception")
    await store.disconnect()
    try check(!store.connected && store.worlds.isEmpty && store.elements.allSatisfy(\.stale), "disconnect cleans frames while retaining stale captures")
    try await store.discoverWebKit(endpoint!)
    await store.connect(target)
    try check(store.connected, "bridge reconnects without reloading target app")
    await store.setPicking(true)
    _ = try await js(view, probe, "/", "document.querySelector('#primary').click()")
    try await wait("before reload capture") { store.elements.first?.tag == "button" }
    let oldFrameID = store.elements[0].world.frameID
    probe.frames = [:]
    view.reload()
    try await wait("reload nested") { probe.frames["/nested.html"] != nil }
    try await wait("old document invalidated") { store.elements.first?.stale == true }
    _ = try await js(view, probe, "/", "document.querySelector('#primary').click()")
    try await wait("picking restored after navigation") { store.elements.first?.stale == false && store.elements.first?.world.frameID != oldFrameID }
    try check(true, "navigation invalidates old documents and new documents inherit picking")
    let second = WKWebView(frame: view.frame, configuration: view.configuration)
    DomScanBridge.shared.attach(to: second)
    second.load(URLRequest(url: URL(string: "http://127.0.0.1:9471/same.html")!))
    try await wait("second view list") { store.targets.count == 2 }
    guard let secondTarget = store.targets.first(where: { $0.id != target.id }) else { throw SelectorError.message("second view missing") }
    await store.connect(secondTarget)
    try check(store.connected, "multiple WKWebViews sharing a userContentController connect independently")
    await store.disconnect()
    print("ALL WKWEBVIEW CHECKS PASSED")
  }
}
