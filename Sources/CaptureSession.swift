import Combine
import Foundation

struct ExecutionWorld: Identifiable, Equatable {
  let sessionID: String
  let contextID: Int
  let uniqueID: String
  let frameID: String
  var id: String { "\(sessionID):\(contextID):\(uniqueID)" }
}

struct SelectedElement: Identifiable {
  let id: String
  let world: ExecutionWorld
  var frameURL: String
  var frameTitle: String
  var capturedFramePath: [String]
  let windowTitle: String
  let windowURL: String
  var snapshot: [String: Any]
  var note = ""
  var stale = false
  var token: String { snapshot["token"] as? String ?? "" }
  var name: String { snapshot["name"] as? String ?? "未命名元素" }
  var tag: String { snapshot["tag"] as? String ?? "element" }
  var selector: String { snapshot["selector"] as? String ?? "" }
}

@MainActor
final class CaptureSession: ObservableObject {
  private let worldName = "DesktopSelector.Isolated.v1." + UUID().uuidString
  @Published var endpoint = "http://127.0.0.1:9222"
  @Published var targets: [DebugTarget] = []
  @Published var browserName = ""
  @Published var selectedTarget: DebugTarget?
  @Published var connected = false
  @Published var picking = false
  @Published var busy = false
  @Published var status = "连接桌面应用，开始选择真实元素"
  @Published var error: String?
  @Published var worlds: [String: ExecutionWorld] = [:]
  @Published var elements: [SelectedElement] = []
  @Published var focusedID: String?
  @Published var frameWarnings: [String] = []
  let cdp = CDPConnection()
  private var scripts: [String: String] = [:]
  private var sessions = Set<String>()
  private var frames: [String: (parent: String?, url: String)] = [:]
  private var generation = UUID()
  private var source: String
  private var rootSession: String?
  private var selectionRevision = 0
  private var stateRevision = 0
  private var heartbeat: Task<Void, Never>?
  private var targetWatch: Task<Void, Never>?
  var onPickModeChanged: ((Bool) -> Void)?

  init(source: String) { self.source = source }

  func discover() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let base = try LocalEndpoint.validate(endpoint)
      let version = try await LocalEndpoint.json("/json/version", base: base)
      let (data, response) = try await LocalEndpoint.fetch("/json/list", base: base)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      else {
        throw SelectorError.message("无法读取应用窗口列表。")
      }
      targets = list.compactMap(DebugTarget.init)
      browserName = version["Browser"] as? String ?? "Chromium"
      status = targets.isEmpty ? "已连接调试端口，当前没有可选择的 HTML 窗口" : "发现 \(targets.count) 个窗口，选择一个接入"
      startTargetWatch()
    } catch {
      targets = []
      browserName = ""
      self.error = "无法连接。请确认目标应用支持并已开启 --remote-debugging-port=9222。\n\(error.localizedDescription)"
      status = "等待桌面应用开放调试连接"
    }
  }

  func connect(_ target: DebugTarget) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    await disconnect()
    error = nil
    frameWarnings = []
    let currentGeneration = generation
    do {
      let version = try await LocalEndpoint.json(
        "/json/version", base: LocalEndpoint.validate(endpoint))
      guard let address = version["webSocketDebuggerUrl"] as? String else {
        throw SelectorError.message("应用未提供浏览器级调试连接。")
      }
      let url = try LocalEndpoint.validate(address, websocket: true)
      cdp.onEvent = { [weak self] method, params, sessionID in
        guard self?.generation == currentGeneration else { return }
        self?.handle(method, params, sessionID)
      }
      cdp.onDisconnect = { [weak self] _ in
        guard let self, self.generation == currentGeneration else { return }
        self.connected = false
        self.picking = false
        for i in self.elements.indices { self.elements[i].stale = true }
        self.worlds = [:]
        self.sessions = []
        self.scripts = [:]
        self.rootSession = nil
        self.status = "应用连接已断开；已采集内容仍可导出"
        self.onPickModeChanged?(false)
      }
      cdp.open(url)
      let result = try await cdp.request(
        "Target.attachToTarget", ["targetId": target.id, "flatten": true])
      guard let sessionID = result["sessionId"] as? String else {
        throw SelectorError.message("无法接入这个窗口。")
      }
      rootSession = sessionID
      selectedTarget = target
      connected = true
      try await setup(sessionID, generation: currentGeneration)
      startHeartbeat()
      startTargetWatch()
      status = "已接入 · 按 ⌘⇧S 开始拾取"
    } catch {
      await disconnect()
      self.error = error.localizedDescription
      status = "接入失败"
    }
  }

  private func startTargetWatch() {
    targetWatch?.cancel()
    let watchedEndpoint = endpoint
    targetWatch = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled, let self, self.endpoint == watchedEndpoint else { return }
        guard !self.busy else { continue }
        do {
          let (data, response) = try await LocalEndpoint.fetch(
            "/json/list", base: LocalEndpoint.validate(watchedEndpoint), timeout: 2)
          guard !Task.isCancelled, self.endpoint == watchedEndpoint,
            (response as? HTTPURLResponse)?.statusCode == 200,
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
          self.targets = rows.compactMap(DebugTarget.init)
          if let selected = self.selectedTarget,
            let updated = self.targets.first(where: { $0.id == selected.id }) {
            self.selectedTarget = updated
          }
        } catch { /* Transient refresh failures must not interrupt an active capture. */ }
      }
    }
  }

  private func setup(_ sessionID: String, generation expected: UUID) async throws {
    guard generation == expected, !sessions.contains(sessionID) else { return }
    sessions.insert(sessionID)
    _ = try await cdp.request("Runtime.enable", sessionID: sessionID)
    _ = try await cdp.request("Page.enable", sessionID: sessionID)
    _ = try await cdp.request(
      "Runtime.addBinding", ["name": "__desktopSelectorEmit", "executionContextName": worldName],
      sessionID: sessionID)
    let result = try await cdp.request(
      "Page.addScriptToEvaluateOnNewDocument", ["source": source, "worldName": worldName],
      sessionID: sessionID)
    if let id = result["identifier"] as? String { scripts[sessionID] = id }
    // Recursively attach related targets: cross-site OOPIFs are separate CDP sessions.
    _ = try await cdp.request(
      "Target.setAutoAttach",
      ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], sessionID: sessionID)
    let tree = try await cdp.request("Page.getFrameTree", sessionID: sessionID)
    if let frameTree = tree["frameTree"] as? [String: Any] {
      await installTree(frameTree, sessionID: sessionID, expected: expected)
    }
  }

  private func installTree(_ tree: [String: Any], sessionID: String, expected: UUID) async {
    guard generation == expected else { return }
    if let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String {
      rememberFrame(frame)
      await installFrame(id, sessionID: sessionID, expected: expected)
    }
    for child in tree["childFrames"] as? [[String: Any]] ?? [] {
      await installTree(child, sessionID: sessionID, expected: expected)
    }
  }

  private func installFrame(_ frameID: String, sessionID: String, expected: UUID) async {
    guard generation == expected, sessions.contains(sessionID) else { return }
    do {
      let result = try await cdp.request(
        "Page.createIsolatedWorld", ["frameId": frameID, "worldName": worldName],
        sessionID: sessionID)
      guard let contextID = result["executionContextId"] as? Int, generation == expected else {
        return
      }
      _ = try await cdp.request(
        "Runtime.evaluate", ["expression": source, "contextId": contextID], sessionID: sessionID)
    } catch {
      // An OOPIF is installed through its own child session, not its parent's.
      if generation == expected { status = "已接入；正在同步 frame" }
    }
  }

  private func rememberFrame(_ frame: [String: Any]) {
    guard let id = frame["id"] as? String else { return }
    frames[id] = (
      frame["parentId"] as? String ?? frames[id]?.parent,
      frame["url"] as? String ?? frames[id]?.url ?? ""
    )
  }

  private func handle(_ method: String, _ params: [String: Any], _ sessionID: String?) {
    let expected = generation
    switch method {
    case "Target.attachedToTarget":
      guard let parent = sessionID, sessions.contains(parent),
        let child = params["sessionId"] as? String,
        let info = params["targetInfo"] as? [String: Any]
      else { return }
      guard ["iframe", "page", "webview"].contains(info["type"] as? String ?? "") else { return }
      Task { [weak self] in
        do { try await self?.setup(child, generation: expected) } catch {
          self?.frameWarnings.append("一个内嵌 frame 暂时无法接入：\(error.localizedDescription)")
        }
      }
    case "Target.detachedFromTarget":
      if let child = params["sessionId"] as? String { removeSession(child) }
    case "Runtime.executionContextCreated":
      guard let sessionID, sessions.contains(sessionID),
        let ctx = params["context"] as? [String: Any],
        ctx["name"] as? String == worldName, let id = ctx["id"] as? Int
      else { return }
      let aux = ctx["auxData"] as? [String: Any] ?? [:]
      let world = ExecutionWorld(
        sessionID: sessionID, contextID: id, uniqueID: ctx["uniqueId"] as? String ?? "\(id)",
        frameID: aux["frameId"] as? String ?? "")
      worlds[world.id] = world
    case "Runtime.executionContextDestroyed":
      guard let sessionID, let id = params["executionContextId"] as? Int else { return }
      for w in worlds.values.filter({ $0.sessionID == sessionID && $0.contextID == id }) {
        removeWorld(w)
      }
    case "Runtime.executionContextsCleared":
      guard let sessionID else { return }
      for w in worlds.values.filter({ $0.sessionID == sessionID }) { removeWorld(w) }
    case "Page.frameAttached":
      if let id = params["frameId"] as? String {
        frames[id] = (params["parentFrameId"] as? String, frames[id]?.url ?? "")
      }
    case "Page.frameNavigated":
      guard let sessionID, let frame = params["frame"] as? [String: Any],
        let id = frame["id"] as? String
      else { return }
      rememberFrame(frame)
      Task { [weak self] in await self?.installFrame(id, sessionID: sessionID, expected: expected) }
    case "Runtime.bindingCalled":
      guard let sessionID, params["name"] as? String == "__desktopSelectorEmit",
        let contextID = params["executionContextId"] as? Int,
        let world = worlds.values.first(where: {
          $0.sessionID == sessionID && $0.contextID == contextID
        }),
        let payload = params["payload"] as? String, payload.utf8.count < 160_000,
        let data = payload.data(using: .utf8),
        let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      receive(message, world: world)
    default: break
    }
  }

  private func removeWorld(_ world: ExecutionWorld) {
    worlds.removeValue(forKey: world.id)
    for i in elements.indices where elements[i].world.id == world.id { elements[i].stale = true }
  }
  private func removeSession(_ sessionID: String) {
    sessions.remove(sessionID)
    scripts.removeValue(forKey: sessionID)
    for world in worlds.values.filter({ $0.sessionID == sessionID }) { removeWorld(world) }
    if sessionID == rootSession {
      connected = false
      picking = false
      heartbeat?.cancel()
      heartbeat = nil
      status = "目标窗口已关闭，已采集内容仍可导出"
      onPickModeChanged?(false)
    }
  }

  private func startHeartbeat() {
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled, let self, self.connected else { return }
        if self.picking {
          for world in Array(self.worlds.values) {
            guard !Task.isCancelled, self.picking else { break }
            try? await self.evaluate("globalThis.__desktopSelector?.renewLease();", world: world)
          }
        }
      }
    }
  }

  private func receive(_ message: [String: Any], world: ExecutionWorld) {
    switch message["kind"] as? String {
    case "ready":
      Task { [weak self] in
        guard let self else { return }
        try? await self.evaluate(
          "globalThis.__desktopSelector?.setActive(\(self.picking));", world: world)
      }
    case "stop": Task { await self.setPicking(false) }
    case "stale":
      if let token = message["token"] as? String,
        let i = elements.firstIndex(where: { $0.world.id == world.id && $0.token == token })
      {
        elements[i].stale = true
      }
    case "selection", "refresh":
      guard let item = message["item"] as? [String: Any], let token = item["token"] as? String,
        !token.isEmpty
      else { return }
      let id = world.id + ":" + token
      if message["kind"] as? String == "refresh" {
        if let i = elements.firstIndex(where: { $0.id == id }) {
          elements[i].snapshot = item
          elements[i].stale = false
          elements[i].frameURL = message["frameURL"] as? String ?? elements[i].frameURL
          elements[i].frameTitle = message["frameTitle"] as? String ?? elements[i].frameTitle
        }
        return
      }
      let additive = message["additive"] as? Bool ?? false
      let oldNote = elements.first(where: { $0.id == id })?.note ?? ""
      if !additive { elements = [] }
      if let index = elements.firstIndex(where: { $0.id == id }) {
        elements.remove(at: index)
        focusedID = elements.last?.id
      } else {
        elements.append(
          SelectedElement(
            id: id, world: world, frameURL: message["frameURL"] as? String ?? "",
            frameTitle: message["frameTitle"] as? String ?? "",
            capturedFramePath: framePath(world.frameID), windowTitle: selectedTarget?.title ?? "",
            windowURL: selectedTarget?.url ?? "", snapshot: item, note: oldNote))
        focusedID = id
      }
      selectionRevision += 1
      status = "已选择 \(elements.count) 个元素 · Shift 点击多选 · Esc 结束拾取"
      Task { await self.syncSelection() }
    default: break
    }
  }

  func setPicking(_ value: Bool) async {
    guard connected else { return }
    picking = value
    stateRevision += 1
    let revision = stateRevision
    for world in Array(worlds.values) {
      guard revision == stateRevision else { return }
      try? await evaluate("globalThis.__desktopSelector?.setActive(\(value));", world: world)
    }
    if revision == stateRevision {
      status = value ? "正在拾取 · 点击选择 · Shift 多选 · Esc 恢复正常操作" : "拾取已暂停，原应用可正常操作"
      onPickModeChanged?(value)
    }
  }

  func activateTarget() async {
    guard let selectedTarget else { return }
    _ = try? await cdp.request("Target.activateTarget", ["targetId": selectedTarget.id])
  }

  private func syncSelection() async {
    let revision = selectionRevision
    for world in Array(worlds.values) {
      guard revision == selectionRevision else { return }
      let tokens = elements.filter { $0.world.id == world.id && !$0.stale }.map(\.token)
      let json = Self.jsonString(tokens)
      try? await evaluate("globalThis.__desktopSelector?.setSelected(\(json));", world: world)
    }
  }

  func clear() {
    elements = []
    focusedID = nil
    selectionRevision += 1
    Task { await syncSelection() }
  }
  func remove(_ id: String) {
    elements.removeAll { $0.id == id }
    if focusedID == id { focusedID = elements.first?.id }
    selectionRevision += 1
    Task { await syncSelection() }
  }
  func note(_ id: String, _ text: String) {
    if let i = elements.firstIndex(where: { $0.id == id }) { elements[i].note = text }
  }
  func navigate(_ element: SelectedElement, direction: String) async {
    guard !element.stale else { return }
    try? await evaluate(
      "globalThis.__desktopSelector?.navigate(\(Self.jsonString(element.token)),\(Self.jsonString(direction)));",
      world: element.world)
  }
  func refresh() async {
    for world in Array(worlds.values) {
      let tokens = elements.filter { $0.world.id == world.id }.map(\.token)
      guard !tokens.isEmpty else { continue }
      try? await evaluate(
        "globalThis.__desktopSelector?.refresh(\(Self.jsonString(tokens)));", world: world)
    }
  }
  func evaluate(_ expression: String, world: ExecutionWorld) async throws {
    guard worlds[world.id] != nil else { throw SelectorError.message("页面已更新，请重新选择元素。") }
    let result = try await cdp.request(
      "Runtime.evaluate",
      ["expression": expression, "uniqueContextId": world.uniqueID, "returnByValue": true],
      sessionID: world.sessionID)
    if result["exceptionDetails"] != nil { throw SelectorError.message("这个 frame 的选择脚本执行失败。") }
  }

  func disconnect() async {
    targetWatch?.cancel()
    targetWatch = nil
    heartbeat?.cancel()
    heartbeat = nil
    picking = false
    stateRevision += 1
    onPickModeChanged?(false)
    for world in Array(worlds.values) {
      try? await evaluate("globalThis.__desktopSelector?.destroy();", world: world)
    }
    for (session, id) in scripts {
      _ = try? await cdp.request(
        "Page.removeScriptToEvaluateOnNewDocument", ["identifier": id], sessionID: session)
    }
    if let rootSession {
      _ = try? await cdp.request("Target.detachFromTarget", ["sessionId": rootSession])
    }
    generation = UUID()
    cdp.onEvent = nil
    cdp.onDisconnect = nil
    cdp.close()
    worlds = [:]
    sessions = []
    scripts = [:]
    frames = [:]
    rootSession = nil
    connected = false
    selectedTarget = nil
    for i in elements.indices { elements[i].stale = true }
  }

  func framePath(_ id: String) -> [String] {
    var path: [String] = []
    var current: String? = id
    var seen = Set<String>()
    while let value = current, !seen.contains(value), path.count < 24 {
      seen.insert(value)
      guard let frame = frames[value] else { break }
      path.insert(frame.url, at: 0)
      current = frame.parent
    }
    return path
  }

  static func jsonString(_ value: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  func exportJSON() -> Data {
    let body: [String: Any] = [
      "schemaVersion": 1, "tool": "DomScan",
      "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "target": ["title": selectedTarget?.title ?? "已断开的窗口", "url": selectedTarget?.url ?? ""],
      "elements": elements.map { e in
        [
          "window": ["title": e.windowTitle, "url": e.windowURL], "frameID": e.world.frameID,
          "frameURL": e.frameURL, "framePath": e.capturedFramePath, "instruction": e.note,
          "stale": e.stale, "element": e.snapshot,
        ] as [String: Any]
      },
    ]
    return
      (try? JSONSerialization.data(
        withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data()
  }

  func exportMarkdown() -> String {
    var lines = [
      "# DomScan", "",
      "Window: \(selectedTarget?.title ?? elements.first?.windowTitle ?? "未接入窗口")",
      "Source: DOM · no screenshot inference", "",
    ]
    for (i, e) in elements.enumerated() {
      lines += [
        "## \(i+1). <\(e.tag)> \(e.name)", "", "Window: \(e.windowTitle)",
        "Frame URL: \(e.frameURL)", "Frame ID: \(e.world.frameID)",
        "Frame path: \(e.capturedFramePath.joined(separator:" → "))", "Selector: \(e.selector)",
      ]
      if e.stale { lines.append("State: stale — captured element is no longer available") }
      if !e.note.isEmpty { lines += ["", "Instruction:", e.note] }
      lines += [
        "", "Text:", Self.fenced(e.snapshot["text"] as? String ?? "", language: "text"), "",
        "Geometry (CSS pixels, relative to this frame):",
        Self.fenced(Self.jsonString(e.snapshot["bounds"] ?? [:]), language: "json"), "",
        "Computed CSS:",
      ]
      let styles = e.snapshot["styles"] as? [String: String] ?? [:]
      lines += [
        Self.fenced(
          styles.keys.sorted().map { "\($0): \(styles[$0]!);" }.joined(separator: "\n"),
          language: "css"), "", "HTML (truncated to 16,000 characters):",
        Self.fenced(e.snapshot["html"] as? String ?? "", language: "html"), "",
      ]
    }
    return lines.joined(separator: "\n")
  }
  private static func fenced(_ text: String, language: String) -> String {
    let maxRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let fence = String(repeating: "`", count: max(3, maxRun + 1))
    return "\(fence)\(language)\n\(text)\n\(fence)"
  }
}
