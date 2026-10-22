import AppKit
import Darwin
import Foundation
import Network
import WebKit

/// Development-only WKWebView adapter. start() is a no-op without the DEBUG Swift flag.
@MainActor
@available(macOS 11.0, *)
public final class DomScanBridge: NSObject, WKScriptMessageHandler {
  public static let shared = DomScanBridge()
  public private(set) var lastError: String?
  private let world = WKContentWorld.world(name: "io.github.shea0116.domscan.bridge.v1")
  private let handler = "domScanBridge"
  private var listener: NWListener?
  private var manifest: URL?
  private var token = UUID().uuidString + UUID().uuidString
  private var peers: [UUID: BridgeWire] = [:]
  private var authenticated: UUID?
  private var selectedView: String?
  private var views: [String: ViewEntry] = [:]
  private var timer: Timer?
  private var source = ""
  private var controllers: [ObjectIdentifier: WKUserContentController] = [:]

  @MainActor private class ViewEntry {
    weak var view: WKWebView?
    var frames: [String: WKFrameInfo] = [:]
    var needsReload: Bool
    var initialMainDocument: String?
    init(_ view: WKWebView) {
      self.view = view
      needsReload = view.url != nil && view.url?.absoluteString != "about:blank"
    }
  }

  /// For Flutter and other platform-view hosts, observe existing and newly inserted WKWebViews.
  /// For complete first-load coverage, prefer attach(to:) before load in a native app.
  public func start(observingWindows: Bool = true) {
    #if DEBUG
    guard listener == nil else { return }
    do {
      #if SWIFT_PACKAGE
      let resourceBundle = Bundle.module
      #else
      let resourceBundle = Bundle.main
      #endif
      guard let url = resourceBundle.url(forResource: "picker", withExtension: "js") else {
        throw BridgeFailure.message("DomScan picker.js resource missing")
      }
      source = try String(contentsOf: url, encoding: .utf8)
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener else { return }
          if case .ready = state, let port = listener.port {
            do { try self.publish(port.rawValue) } catch { self.lastError = error.localizedDescription; self.stop() }
          }
          if case .failed(let error) = state { self.lastError = error.localizedDescription; self.stop() }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      listener.start(queue: .main)
      if observingWindows {
        scanWindows()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
          Task { @MainActor in self?.scanWindows() }
        }
      }
    } catch { lastError = error.localizedDescription }
    #endif
  }

  /// Call before the first load to cover same-origin, cross-origin and nested frames.
  public func attach(to webView: WKWebView) {
    #if DEBUG
    if listener == nil { start(observingWindows: false) }
    guard listener != nil, !source.isEmpty,
      !views.values.contains(where: { $0.view === webView }) else { return }
    let id = UUID().uuidString
    views[id] = ViewEntry(webView)
    let controller = webView.configuration.userContentController
    let preamble = """
      (() => {
        if (globalThis.__domScanDocument) return;
        const documentID = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
        globalThis.__domScanDocument = documentID;
        globalThis.__desktopSelectorEmit = payload => {
          window.webkit.messageHandlers.domScanBridge.postMessage({frameID:documentID,payload});
        };
        addEventListener('pagehide', () => {
          globalThis.__desktopSelector?.setActive(false);
          __desktopSelectorEmit(JSON.stringify({kind:'gone'}));
        });
        addEventListener('pageshow', () => {
          __desktopSelectorEmit(JSON.stringify({kind:'ready',frameURL:location.href,frameTitle:document.title}));
        });
      })();
      """
    let script = preamble + "\n" + source
    if controllers[ObjectIdentifier(controller)] == nil {
      controllers[ObjectIdentifier(controller)] = controller
      controller.add(self, contentWorld: world, name: handler)
      controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
        forMainFrameOnly: false, in: world))
    }
    // Already loaded views expose their main frame now; existing cross-origin frames
    // are covered after the next page reload, since public WebKit has no frame enumeration API.
    webView.evaluateJavaScript(script, in: nil, in: world) { _ in }
    #endif
  }

  public func stop() {
    timer?.invalidate(); timer = nil
    for wire in Array(peers.values) { wire.close() }
    peers = [:]; authenticated = nil; selectedView = nil
    for entry in views.values {
      if let view = entry.view {
        for (id, frame) in entry.frames { run(view, frame, id, "destroy", []) { _ in } }
      }
    }
    views = [:]
    for controller in controllers.values {
      controller.removeScriptMessageHandler(forName: handler, contentWorld: world)
    }
    controllers = [:]
    listener?.cancel(); listener = nil
    if let manifest { try? FileManager.default.removeItem(at: manifest) }
    manifest = nil
  }

  private func scanWindows() {
    func visit(_ view: NSView) {
      if let web = view as? WKWebView { attach(to: web); return }
      for child in view.subviews { visit(child) }
    }
    for window in NSApp.windows { visit(window.contentView ?? NSView()) }
    for (id, entry) in views where entry.view == nil {
      if selectedView == id { peers[authenticated ?? UUID()]?.send(["event": "closed"]) }
      views.removeValue(forKey: id)
    }
  }

  private func publish(_ port: UInt16) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.shea0116.domscan", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
      throw BridgeFailure.message("DomScan bridge directory must be private to this user")
    }
    let file = directory.appendingPathComponent("\(getpid()).json")
    let data = try JSONSerialization.data(withJSONObject: ["protocol": 1, "pid": getpid(), "port": port, "token": token])
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    manifest = file
  }

  private func accept(_ connection: NWConnection) {
    guard peers.count < 4 else { connection.cancel(); return }
    let id = UUID(), wire = BridgeWire(connection)
    peers[id] = wire
    wire.onMessage = { [weak self, weak wire] message in
      guard let self, let wire, let request = message["id"] as? Int,
        let method = message["method"] as? String else { wire?.close(); return }
      let params = message["params"] as? [String: Any] ?? [:]
      if self.authenticated != id {
        guard method == "hello", params["token"] as? String == self.token,
          params["pid"] as? Int == Int(getpid()), params["protocol"] as? Int == 1,
          self.authenticated == nil else { wire.close(); return }
        self.authenticated = id
        wire.send(["reply": request, "result": ["protocol": 1, "pid": getpid()]])
        return
      }
      Task { @MainActor in
        do {
          let result = try await self.handle(method, params)
          wire.send(["reply": request, "result": result])
        } catch { wire.send(["reply": request, "error": error.localizedDescription]) }
      }
    }
    wire.onClose = { [weak self] in
      guard let self else { return }
      self.peers.removeValue(forKey: id)
      if self.authenticated == id {
        self.releaseInput()
        self.authenticated = nil; self.selectedView = nil
      }
    }
    wire.start()
    Task { [weak self, weak wire] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      if self?.authenticated != id { wire?.close() }
    }
  }

  private func handle(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    if method == "list" {
      return ["targets": views.compactMap { id, entry -> [String: Any]? in
        guard let view = entry.view else { return nil }
        return ["id": id, "type": "webview", "title": view.title ?? view.window?.title ?? "WKWebView",
          "url": view.url?.absoluteString ?? "about:blank", "needsReload": entry.needsReload]
      }]
    }
    if method == "detach" { releaseInput(); selectedView = nil; return [:] }
    if method == "attach", let id = params["target"] as? String, let entry = views[id], entry.view != nil {
      releaseInput(); selectedView = id
      for (frameID, frame) in entry.frames { announce(id, frameID, frame, ["kind": "ready"]) }
      return ["frames": entry.frames.count]
    }
    guard method == "command", let viewID = selectedView, let entry = views[viewID], let view = entry.view,
      let frameID = params["frame"] as? String, let frame = entry.frames[frameID],
      let command = params["command"] as? String,
      ["setActive", "renewLease", "setSelected", "navigate", "refresh", "destroy"].contains(command),
      let args = params["args"] as? [Any], args.count <= 2 else {
      throw BridgeFailure.message("WKWebView 或 frame 已变化，请重新选择。")
    }
    return try await withCheckedThrowingContinuation { continuation in
      run(view, frame, frameID, command, args) { continuation.resume(with: $0) }
    }
  }

  private func run(_ view: WKWebView, _ frame: WKFrameInfo, _ frameID: String, _ command: String,
    _ args: [Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    view.callAsyncJavaScript("""
      if (globalThis.__domScanDocument !== documentID || !globalThis.__desktopSelector) throw Error('Document changed');
      globalThis.__desktopSelector[command](...args);
      return true;
      """, arguments: ["documentID": frameID, "command": command, "args": args], in: frame, in: world) { result in
      completion(result.map { _ in [:] })
    }
  }
  private func releaseInput() {
    for entry in views.values {
      guard let view = entry.view else { continue }
      for (id, frame) in entry.frames {
        run(view, frame, id, "setActive", [false]) { _ in }
        run(view, frame, id, "setSelected", [[]]) { _ in }
      }
    }
  }
  public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
      let (viewID, entry) = views.first(where: { $0.value.view === message.webView }),
      let frameID = body["frameID"] as? String, frameID.count < 64,
      let payload = body["payload"] as? String, payload.utf8.count < 160_000,
      let data = payload.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if message.frameInfo.isMainFrame, event["kind"] as? String == "ready" {
      if let initial = entry.initialMainDocument, initial != frameID { entry.needsReload = false }
      if entry.initialMainDocument == nil { entry.initialMainDocument = frameID }
    }
    if event["kind"] as? String == "gone" { entry.frames.removeValue(forKey: frameID) }
    else { entry.frames[frameID] = message.frameInfo }
    if selectedView == viewID { announce(viewID, frameID, message.frameInfo, event) }
  }
  private func announce(_ viewID: String, _ frameID: String, _ frame: WKFrameInfo, _ event: [String: Any]) {
    peers[authenticated ?? UUID()]?.send(["event": "frame", "view": viewID, "frame": frameID,
      "main": frame.isMainFrame, "url": frame.request.url?.absoluteString ?? "",
      "message": event])
  }
}
