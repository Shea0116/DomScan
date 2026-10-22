import Foundation

@main
struct Integration {
  @MainActor static func main() async {
    do {
      try await run()
      exit(0)
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
  @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw SelectorError.message("Timeout: \(label)")
  }
  static func check(_ value: Bool, _ label: String) throws {
    if !value { throw SelectorError.message(label) }
    print("PASS \(label)")
  }

  @MainActor static func run() async throws {
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let store = CaptureSession(source: source)
    store.endpoint =
      CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "http://127.0.0.1:9444"
    for bad in [
      "http://example.com:9222", "http://127.0.0.1.evil.test:9222", "file:///tmp/a",
      "http://u:p@localhost:9222",
    ] {
      do {
        _ = try LocalEndpoint.validate(bad)
        throw SelectorError.message("Accepted invalid endpoint")
      } catch SelectorError.message(let msg) where msg != "Accepted invalid endpoint" {}
    }
    try check(true, "non-loopback and credential endpoints rejected")
    await store.discover()
    guard
      let target = store.targets.first(where: { $0.title.contains("Selector Fixture") })
        ?? store.targets.first
    else { throw SelectorError.message(store.error ?? "Fixture not found") }
    await store.connect(target)
    try check(store.connected, "connected to real Chromium debug target")
    var root: ExecutionWorld?
    var cross: ExecutionWorld?
    var nested: ExecutionWorld?
    for _ in 0..<100 {
      for w in Array(store.worlds.values) {
        guard let r = try? await store.cdp.request(
          "Runtime.evaluate",
          ["expression": "({path:location.pathname,ready:!!globalThis.__desktopSelector})", "uniqueContextId": w.uniqueID, "returnByValue": true],
          sessionID: w.sessionID),
          let value = (r["result"] as? [String: Any])?["value"] as? [String: Any],
          value["ready"] as? Bool == true else { continue }
        let path = value["path"] as? String
        if path == "/" { root = w }
        if path == "/cross.html" { cross = w }
        if path == "/nested.html" { nested = w }
      }
      if root != nil && cross != nil && nested != nil { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let root, let cross, let nested else {
      throw SelectorError.message("Missing expected frames")
    }
    try check(true, "same-origin, cross-site and nested frames attached and ready")
    try check(root.sessionID != cross.sessionID, "cross-site iframe uses a separate OOPIF session")
    await store.setPicking(true)
    try await store.evaluate("document.querySelector('#primary').click();", world: root)
    try await wait("root pick") { store.elements.count == 1 }
    try check(store.elements[0].selector.contains("save-button"), "stable DOM selector captured")
    try check(store.elements[0].snapshot["styles"] is [String: String], "computed CSS captured")
    let rect = store.elements[0].snapshot["bounds"] as! [String: Double]
    let x = rect["x"]! + rect["width"]! / 2
    let y = rect["y"]! + rect["height"]! / 2
    _ = try await store.cdp.request(
      "Input.dispatchMouseEvent",
      ["type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1],
      sessionID: root.sessionID)
    _ = try await store.cdp.request(
      "Input.dispatchMouseEvent",
      ["type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1],
      sessionID: root.sessionID)
    let pointer = try await store.cdp.request(
      "Runtime.evaluate", ["expression": "window.pointerCount", "returnByValue": true],
      sessionID: root.sessionID)
    try check(
      (pointer["result"] as? [String: Any])?["value"] as? Int == 0,
      "trusted pointerdown does not trigger target action while picking")
    let counter = try await store.cdp.request(
      "Runtime.evaluate", ["expression": "window.clickCount", "returnByValue": true],
      sessionID: root.sessionID)
    try check(
      (counter["result"] as? [String: Any])?["value"] as? Int == 0,
      "picking suppresses the selected button action")
    try await store.evaluate(
      "document.querySelector('#frame-button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}));",
      world: cross)
    try await wait("cross pick") { store.elements.count == 2 }
    try await store.evaluate(
      "document.querySelector('#frame-button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}));",
      world: nested)
    try await wait("nested pick") { store.elements.count == 3 }
    try check(
      store.elements.last?.frameURL.contains("nested.html") == true,
      "nested frame identity retained")
    try await store.evaluate(
      "document.querySelector('#shadow-host').shadowRoot.querySelector('button').dispatchEvent(new MouseEvent('click',{bubbles:true,composed:true,shiftKey:true}));",
      world: root)
    try await wait("shadow pick") { store.elements.count == 4 }
    try check(
      (store.elements.last?.snapshot["shadowPath"] as? [String])?.count == 2,
      "open Shadow DOM locator retained")
    let id = store.elements[0].id
    store.note(id, "改成绿色，并保留加载状态")
    let markdown = store.exportMarkdown()
    try check(
      markdown.contains("改成绿色") && markdown.contains("nested.html")
        && markdown.contains("Computed CSS"), "Markdown includes instruction, iframe origin and CSS"
    )
    try check(
      (try JSONSerialization.jsonObject(with: store.exportJSON()) as? [String: Any])?[
        "schemaVersion"] as? Int == 1, "JSON export is valid and versioned")
    let oldWorldCount = store.worlds.count
    _ = try await store.cdp.request(
      "Runtime.evaluate",
      [
        "expression":
          "(()=>{const f=document.createElement('iframe');f.id='dynamic';f.src='http://localhost:9472/dynamic.html';document.body.append(f)})()"
      ], sessionID: root.sessionID)
    try await wait("dynamic iframe") { store.worlds.count > oldWorldCount }
    try check(true, "new iframe automatically attached while picking")
    // Esc inside a child frame must turn off picking in every frame.
    try await store.evaluate(
      "window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));",
      world: cross)
    try await wait("Escape stops picking") { !store.picking }
    try await Task.sleep(nanoseconds: 300_000_000)
    _ = try await store.cdp.request(
      "Runtime.evaluate",
      [
        "expression":
          "document.querySelector('#primary').click();document.querySelector('#editor').value='normal input';window.clickCount",
        "returnByValue": true,
      ], sessionID: root.sessionID)
    let after = try await store.cdp.request(
      "Runtime.evaluate", ["expression": "window.clickCount", "returnByValue": true],
      sessionID: root.sessionID)
    try check(
      (after["result"] as? [String: Any])?["value"] as? Int == 1,
      "normal click restored after Escape")
    // Actual input events verify focus and typing rather than assigning a value.
    _ = try await store.cdp.request(
      "Runtime.evaluate", ["expression": "document.querySelector('#editor').focus()"],
      sessionID: root.sessionID)
    _ = try await store.cdp.request(
      "Input.insertText", ["text": "typed after escape"], sessionID: root.sessionID)
    let input = try await store.cdp.request(
      "Runtime.evaluate",
      ["expression": "document.querySelector('#editor').value", "returnByValue": true],
      sessionID: root.sessionID)
    try check(
      ((input["result"] as? [String: Any])?["value"] as? String)?.contains("typed after escape")
        == true, "typing in the target app restored after Escape")
    let countBefore = store.elements.count
    _ = try await store.cdp.request(
      "Runtime.evaluate", ["expression": "document.querySelector('#cross').remove()"],
      sessionID: root.sessionID)
    try await wait("detached frame invalidation") { store.elements.contains { $0.stale } }
    try check(
      store.elements.count == countBefore, "detached-frame captures retained and marked stale")
    // Simulate a native heartbeat loss: the page must release input itself.
    await store.setPicking(true)
    try await store.evaluate("globalThis.__desktopSelector.renewLease=()=>{};", world: root)
    try await wait("lease expiry releases picking") { !store.picking }
    try check(true, "page releases input after native heartbeat loss")
    let reportDirectory =
      CommandLine.arguments.count > 3
      ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
      : FileManager.default.temporaryDirectory.appendingPathComponent(
        "desktop-selector-verification", isDirectory: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    try store.exportJSON().write(to: reportDirectory.appendingPathComponent("capture.json"))
    try store.exportMarkdown().write(
      to: reportDirectory.appendingPathComponent("capture.md"), atomically: true, encoding: .utf8)
    let beforeDisconnect = try JSONSerialization.jsonObject(with: store.exportJSON()) as! [String: Any]
    let previousCaptures = beforeDisconnect["elements"] as! [[String: Any]]
    let previousPath = previousCaptures.first?["framePath"] as? [String] ?? []
    await store.disconnect()
    try check(!store.connected && store.worlds.isEmpty, "disconnect closes all frame sessions")
    let disconnectedReport = try JSONSerialization.jsonObject(with: store.exportJSON()) as! [String: Any]
    let captures = disconnectedReport["elements"] as! [[String: Any]]
    try check(
      !previousPath.isEmpty && (captures.first?["framePath"] as? [String]) == previousPath,
      "captured frame paths preserved after disconnect")
    print("ALL INTEGRATION CHECKS PASSED")
  }
}
