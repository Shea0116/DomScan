import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DesktopWindow: Identifiable {
  let id: Int
  let processID: pid_t
  let title: String
  let owner: String
  let bounds: CGRect
}

struct DesktopApplication: Identifiable {
  let processID: pid_t?
  let name: String
  let bundleURL: URL
  let icon: NSImage?
  let supportsLaunch: Bool
  let windows: [DesktopWindow]
  var id: String { "\(bundleURL.path):\(processID ?? 0)" }

  static func hasChromiumEngine(_ bundleURL: URL) -> Bool {
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
    if names.contains(where: {
      $0 == "Electron Framework.framework" || $0 == "Chromium Framework.framework"
    }) { return true }
    // Chromium distributions rename their framework. Identify the resource layout,
    // not the application's name, bundle identifier, or framework branding.
    let candidates = [bundleURL.appendingPathComponent("Contents/Resources")]
      + names.filter { $0.hasSuffix(".framework") }.map {
        frameworks.appendingPathComponent($0).appendingPathComponent("Resources")
      }
    return candidates.contains { resources in
      let files = Set((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
      return files.contains("icudtl.dat") && files.contains("resources.pak")
        && (!files.isDisjoint(with: ["chrome_100_percent.pak", "chrome_200_percent.pak"]))
    }
  }

  static func windowsOnScreen() -> [DesktopWindow] {
    let entries =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return entries.compactMap { entry in
      guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
        pid != ProcessInfo.processInfo.processIdentifier,
        entry[kCGWindowLayer as String] as? Int == 0,
        let id = entry[kCGWindowNumber as String] as? Int,
        let raw = entry[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.width > 60,
        rect.height > 60
      else { return nil }
      return DesktopWindow(
        id: id, processID: pid, title: entry[kCGWindowName as String] as? String ?? "",
        owner: entry[kCGWindowOwnerName as String] as? String ?? "应用", bounds: rect)
    }
  }

  static func running() -> [DesktopApplication] {
    let windows = windowsOnScreen()
    return NSWorkspace.shared.runningApplications.compactMap { app in
      guard !app.isTerminated, app.activationPolicy == .regular,
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
        let bundleURL = app.bundleURL
      else { return nil }
      if let ownID = Bundle.main.bundleIdentifier, app.bundleIdentifier == ownID { return nil }
      return DesktopApplication(
        processID: app.processIdentifier,
        name: app.localizedName ?? bundleURL.deletingPathExtension().lastPathComponent,
        bundleURL: bundleURL, icon: app.icon, supportsLaunch: hasChromiumEngine(bundleURL),
        windows: windows.filter { $0.processID == app.processIdentifier })
    }.sorted {
      if $0.supportsLaunch != $1.supportsLaunch { return $0.supportsLaunch }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
}

enum ConnectionCapability: Int {
  case interface, bridge, chromium, unknown

  var label: String {
    switch self {
    case .interface: return "已发现 HTML 接口"
    case .bridge: return "已发现 WebKit 桥接"
    case .chromium: return "检测到 Chromium"
    case .unknown: return "接入待确认"
    }
  }
}

struct ConnectionStep: Identifiable {
  enum Status: String { case pending = "等待", running = "进行中", success = "完成", failed = "未完成" }
  let id: Int
  let title: String
  var status: Status = .pending
  var detail = ""
}

enum ProcessDiscovery {
  // Only parse argv. Environment values returned after argv are never inspected or retained.
  static func arguments(for pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 8_388_608 else { return nil }
    var data = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
    let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard count > 0, count < 10_000 else { return nil }
    var offset = MemoryLayout<Int32>.size
    while offset < size && data[offset] != 0 { offset += 1 }
    while offset < size && data[offset] == 0 { offset += 1 }
    var result: [String] = []
    for _ in 0..<count {
      guard offset < size else { return nil }
      let start = offset
      while offset < size && data[offset] != 0 { offset += 1 }
      result.append(String(decoding: data[start..<offset], as: UTF8.self))
      offset += 1
    }
    return result
  }

  static func listeningPorts(for pid: pid_t) -> [Int] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
    if process.isRunning { process.terminate() }
    let killDeadline = Date().addingTimeInterval(0.3)
    while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard data.count < 131_072 else { return [] }
    let ports = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
      line -> Int? in
      guard line.first == "n", let tail = line.split(separator: ":").last, let port = Int(tail),
        (1...65535).contains(port)
      else { return nil }
      return port
    }
    return Array(Set(ports)).sorted()
  }

  static func launchArguments(from original: [String], port: Int) -> [String] {
    var result: [String] = []
    var skipNext = false
    for arg in original.dropFirst() {
      if skipNext {
        skipNext = false
        continue
      }
      if arg == "--remote-debugging-port" || arg == "--remote-debugging-address" {
        skipNext = true
        continue
      }
      if arg.hasPrefix("--remote-debugging-port=") || arg.hasPrefix("--remote-debugging-address=")
        || arg == "--remote-debugging-pipe" || arg.hasPrefix("-psn_")
      {
        continue
      }
      result.append(arg)
    }
    return result + ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
  }

  static func availablePort() throws -> Int {
    let socketID = socket(AF_INET, SOCK_STREAM, 0)
    guard socketID >= 0 else { throw SelectorError.message("无法为应用准备连接。") }
    defer { close(socketID) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketID, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw SelectorError.message("无法为应用准备连接。") }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let found = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketID, $0, &size) }
    }
    guard found == 0 else { throw SelectorError.message("无法为应用准备连接。") }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}

@MainActor
final class ApplicationConnector: ObservableObject {
  enum State: Equatable {
    case idle, searching, ready, needsRestart, unsupported, launching, failed
  }
  enum Failure { case connection, bridge, launch }
  @Published var applications: [DesktopApplication] = []
  @Published var selectedApplication: DesktopApplication?
  @Published var state: State = .idle
  @Published var busy = false
  @Published var selectingWindow = false
  @Published private(set) var inspectionProfile: URL?
  @Published var message = "直接点选屏幕窗口，或从正在运行的应用中选择。"
  @Published private(set) var failure: Failure?
  @Published private(set) var capabilities: [String: ConnectionCapability] = [:]
  @Published private(set) var diagnosticSteps: [ConnectionStep] = []
  @Published private(set) var portDiagnostics: [String] = []
  @Published private(set) var diagnosticStartedAt: Date?
  private var diagnosticEndpoint: String?
  private var diagnosticEngine = "unconfirmed"
  @Published private(set) var nativeCapturing = false
  var onShowWindow: (() -> Void)?
  var onHideWindow: (() -> Void)?
  let capture: CaptureSession
  private var picker: DesktopWindowPicker?
  private var preferredTitle = ""
  private var selectedLaunchArguments: [String]?
  private var observers: [NSObjectProtocol] = []
  private let inspectionRoot: URL

  private func beginDiagnostics(engine: String = "unconfirmed") {
    diagnosticStartedAt = Date()
    diagnosticEndpoint = nil
    diagnosticEngine = engine
    portDiagnostics = []
    diagnosticSteps = ["识别应用", "发现接口", "获取页面", "接入拾取"].enumerated().map {
      ConnectionStep(id: $0.offset, title: $0.element)
    }
  }
  private func step(_ id: Int, _ status: ConnectionStep.Status, _ detail: String) {
    guard diagnosticSteps.indices.contains(id) else { return }
    diagnosticSteps[id].status = status
    diagnosticSteps[id].detail = detail
  }
  func recordConnectionResult() {
    if capture.connected { state = .ready; failure = nil }
    step(3, capture.connected ? .success : .failed,
      capture.connected ? "HTML 已连接，可以开始拾取" : "目标页面连接失败或尚未就绪，请重试或选择其他页面")
  }
  func diagnosticReport() -> String {
    var lines = ["DomScan connection diagnostics", "Version: 0.5.0",
      "Started: \(diagnosticStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not started")",
      "Application: \(selectedApplication?.name ?? "manual")",
      "Bundle ID: \(selectedApplication.flatMap { Bundle(url: $0.bundleURL)?.bundleIdentifier } ?? "unknown")",
      "PID: \(selectedApplication?.processID.map(String.init) ?? "none")",
      "Engine: \(diagnosticEngine)",
      "HTML connected: \(capture.connected)", "Pages: \(capture.targets.count)", "Frames: \(capture.worlds.count)"]
    if let endpoint = diagnosticEndpoint, let address = try? LocalEndpoint.validate(endpoint),
      let host = address.host {
      lines.append("Local endpoint: \(address.scheme ?? "http")://\(host):\(address.port ?? 80)")
    }
    lines += diagnosticSteps.map { "\($0.title): \($0.status.rawValue) · \($0.detail)" }
    lines += portDiagnostics
    lines.append("采集内容、页面地址、启动参数及桥接凭据不包含在此报告中。")
    return lines.joined(separator: "\n")
  }

  func captureNative(region: Bool) {
    guard !busy, !capture.busy, !selectingWindow, let app = selectedApplication,
      let pid = app.processID,
      NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL == app.bundleURL.standardizedFileURL
    else { return }
    guard region ? CGPreflightScreenCaptureAccess() : AXIsProcessTrusted() else {
      capture.error = region ? "请先允许屏幕录制权限，再重试框选截图。" : "请先允许辅助功能权限，再重试点选原生控件。"
      if region { NativeCapture.requestScreenPermission() } else { NativeCapture.requestAccessibilityPermission() }
      return
    }
    selectingWindow = true
    nativeCapturing = true
    capture.error = nil
    Task {
      await capture.setPicking(false)
      guard selectingWindow else { return }
      onHideWindow?()
      activateSelectedApplication()
      // Let the target's activation notification finish before installing the overlay's
      // focus-loss observer, which otherwise treats that notification as cancellation.
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard selectingWindow else { return }
      let selector = DesktopWindowPicker()
      picker = selector
      selector.startElement(processID: pid, region: region) { [weak self] selection in
        guard let self else { return }
        self.picker = nil
        self.selectingWindow = false
        guard let selection else {
          self.nativeCapturing = false
          self.onShowWindow?()
          self.capture.status = "原生采集已取消"
          return
        }
        self.busy = true
        Task {
          defer { self.busy = false; self.nativeCapturing = false; self.onShowWindow?() }
          do {
            guard NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL
              == app.bundleURL.standardizedFileURL else {
              throw SelectorError.message("目标应用进程已变化，请重新选择。")
            }
            let snapshot: [String: Any]
            if region {
              snapshot = try await NativeCapture.screenshot(selection)
            } else {
              snapshot = try NativeCapture.accessibilitySnapshot(at: selection.point, pid: pid)
            }
            self.capture.addNativeCapture(snapshot,
              windowTitle: selection.window.title.isEmpty ? app.name : selection.window.title)
          } catch { self.capture.error = error.localizedDescription }
        }
      }
    }
  }

  init(capture: CaptureSession, inspectionRoot: URL? = nil) {
    self.capture = capture
    self.inspectionRoot = inspectionRoot ?? Self.defaultInspectionRoot()
    refreshApplications()
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in
          Task { @MainActor in self?.refreshApplications() }
        })
    }
  }

  private static func defaultInspectionRoot() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let current = support.appendingPathComponent("DomScan/Inspection Profiles", isDirectory: true)
    let legacy = support.appendingPathComponent("Desktop Selector/Inspection Profiles", isDirectory: true)
    // Reuse existing profiles without moving files used by a running target application.
    if !FileManager.default.fileExists(atPath: current.path),
      FileManager.default.fileExists(atPath: legacy.path) { return legacy }
    return current
  }

  func refreshApplications() {
    applications = DesktopApplication.running()
    capabilities = Dictionary(uniqueKeysWithValues: applications.map { app in
      let bridge = app.processID.flatMap { WebKitEndpoint.find(pid: $0, bundleURL: app.bundleURL) }
      return (app.id, bridge != nil ? .bridge : app.supportsLaunch ? .chromium : .unknown)
    })
  }

  func capability(for app: DesktopApplication) -> ConnectionCapability {
    if selectedApplication?.id == app.id, state == .ready { return .interface }
    return capabilities[app.id] ?? (app.supportsLaunch ? .chromium : .unknown)
  }

  var connectionLabel: String {
    if nativeCapturing { return "正在采集原生界面" }
    if busy {
      if state == .launching { return "正在准备检查入口" }
      return selectedApplication == nil ? "正在检查 HTML 接口" : "窗口已选中 · 正在检查接口"
    }
    if capture.connected { return "HTML 已连接" }
    return selectedApplication == nil ? "HTML 未连接" : "窗口已选中 · HTML 未连接"
  }

  var offersInspectionInstance: Bool { state == .needsRestart }
  var offersRetry: Bool {
    !capture.connected && !busy && selectedApplication != nil
      && (state == .failed || state == .idle
        || (state == .ready && (capture.selectedTarget != nil || capture.error != nil)))
  }
  var offersBridgeGuide: Bool { state == .unsupported || failure == .bridge }

  var guidanceMessage: String {
    if state == .ready && !capture.connected {
      if let error = capture.error { return error }
      if capture.selectedTarget != nil { return "HTML 连接已断开，请重新尝试连接。" }
      return capture.targets.isEmpty
        ? "已发现接口，当前没有可选择的 HTML 页面。请在目标应用中打开页面，窗口列表会自动更新。"
        : "已发现接口，请从左侧“选择前端窗口”中选择需要检查的页面。"
    }
    return message
  }

  var sidebarMessage: String {
    if state == .unsupported {
      return "尚未发现 HTML 接口。可选原生控件采集或区域截图；DOM 接入方法见右侧。"
    }
    return guidanceMessage
  }

  func openBridgeGuide() {
    if let url = Bundle.main.url(forResource: "WKWebView", withExtension: "md") {
      NSWorkspace.shared.open(url)
    }
  }

  func openNativeGuide() {
    if let url = Bundle.main.url(forResource: "NativeCapture", withExtension: "md") {
      NSWorkspace.shared.open(url)
    }
  }

  func discoverManually() async {
    guard !busy, !capture.busy else { return }
    busy = true
    defer { busy = false }
    beginDiagnostics()
    step(0, .success, "手动连接本机检查接口")
    step(1, .running, "检查本机连接地址")
    diagnosticEndpoint = capture.endpoint
    await capture.disconnect()
    capture.archiveCurrentCapture()
    capture.applicationName = "手动连接"
    selectedApplication = nil
    failure = nil
    state = .searching
    await capture.discover()
    if capture.error == nil { diagnosticEngine = "Chromium / CDP" }
    step(1, capture.error == nil ? .success : .failed, capture.error == nil ? "本机检查接口可用" : "本机接口连接失败，请检查地址与端口")
    step(2, capture.error == nil ? .success : .pending, "发现 \(capture.targets.count) 个页面")
    state = capture.error == nil ? .ready : .failed
    message = capture.error ?? capture.status
    if capture.targets.count == 1, let target = capture.targets.first {
      await capture.connect(target)
      recordConnectionResult()
      if !capture.connected { state = .failed; message = capture.error ?? "窗口接入失败，请重试。" }
    }
  }

  func disconnect() async {
    await capture.disconnect()
    state = .idle
    message = "已断开，随时可以重新连接。"
  }

  func activateSelectedApplication() {
    if let pid = selectedApplication?.processID,
      let running = NSRunningApplication(processIdentifier: pid),
      running.bundleURL?.standardizedFileURL == selectedApplication?.bundleURL.standardizedFileURL
    {
      running.activate(options: [])
    }
  }

  func pickWindow() {
    if cancelWindowPickingIfActive() { return }
    guard !busy, !capture.busy else { return }
    selectingWindow = true
    Task {
      await capture.setPicking(false)
      guard selectingWindow else { return }
      let selector = DesktopWindowPicker()
      picker = selector
      NSApp.unhide(nil)
      onHideWindow?()
      selector.start { [weak self] window in
        guard let self else { return }
        self.picker = nil
        self.selectingWindow = false
        self.onShowWindow?()
        guard let window else {
          self.capture.status = "窗口选择已取消，已恢复正常操作"
          return
        }
        self.refreshApplications()
        guard let app = self.applications.first(where: { $0.processID == window.processID }) else {
          self.message = "这个窗口暂不支持接入，请从应用列表选择它的主应用。"
          return
        }
        Task {
          await self.select(app, windowTitle: window.title)
          if self.capture.connected {
            await self.capture.setPicking(true)
            await self.capture.activateTarget()
            self.activateSelectedApplication()
            NSApp.hide(nil)
          }
        }
      }
    }
  }

  @discardableResult func cancelWindowPickingIfActive() -> Bool {
    guard selectingWindow || picker != nil else { return false }
    if let picker {
      picker.cancel()
    } else {
      selectingWindow = false
      nativeCapturing = false
      onShowWindow?()
    }
    return true
  }

  func select(_ app: DesktopApplication, windowTitle: String = "") async {
    guard !busy, !capture.busy else { return }
    busy = true
    defer { busy = false }
    beginDiagnostics(engine: app.supportsLaunch ? "Chromium" : "unconfirmed")
    step(0, .running, "正在识别目标应用")
    selectedApplication = app
    inspectionProfile = nil
    selectedLaunchArguments = nil
    preferredTitle = windowTitle
    state = .searching
    failure = nil
    message = "正在连接「\(app.name)」…"
    await capture.disconnect()
    capture.archiveCurrentCapture()
    capture.applicationName = app.name
    capture.status = "已选窗口，正在检查 HTML 接口 · \(app.name)"
    capture.error = nil
    capture.targets = []
    step(0, .success, app.supportsLaunch ? "检测到 Chromium 引擎" : "引擎类型待确认，将继续检查接口")
    step(1, .running, "检查 WKWebView 桥接及进程监听端口")
    if let pid = app.processID,
      let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
      running.bundleURL?.standardizedFileURL == app.bundleURL.standardizedFileURL
    {
      selectedLaunchArguments = ProcessDiscovery.arguments(for: pid)
      if let argument = selectedLaunchArguments?.first(where: {
        $0.hasPrefix("--user-data-dir=" + inspectionRoot.path + "/")
      }) {
        inspectionProfile = URL(fileURLWithPath: String(argument.dropFirst("--user-data-dir=".count)))
      }
    }
    if let pid = app.processID,
      NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL
        == app.bundleURL.standardizedFileURL,
      let bridge = WebKitEndpoint.find(pid: pid, bundleURL: app.bundleURL) {
      diagnosticEngine = "WKWebView / DomScanBridge"
      step(1, .success, "发现 WKWebView 桥接")
      step(2, .running, "读取 WKWebView 页面列表")
      do {
        try await capture.discoverWebKit(bridge)
        state = .ready
        step(2, .success, "发现 \(capture.targets.count) 个 WKWebView")
        message = "已找到 \(capture.targets.count) 个 WKWebView。"
        let available = capture.targets.filter { !$0.isPlaceholder }
        let matched = windowTitle.isEmpty ? nil : available.first { $0.title == windowTitle }
        if let target = matched ?? (available.count == 1 ? available.first : nil) {
          step(3, .running, "接入目标页面")
          await capture.connect(target)
          recordConnectionResult()
          message = capture.connected ? "WKWebView 已接入，可以开始拾取。" : capture.error ?? "等待网页加载。"
        }
      } catch {
        state = .failed
        failure = .bridge
        step(2, .failed, "桥接握手或页面读取失败，请确认 Debug 桥接仍在运行")
        message = "WKWebView 桥接无法连接：\(error.localizedDescription) 请确认正在运行的是接入桥接后的 Debug 构建。"
      }
      return
    }
    if let pid = app.processID,
      NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL
        == app.bundleURL.standardizedFileURL,
      let endpoint = await findEndpoint(pid)
    {
      await attach(endpoint, preferredTitle: windowTitle)
    } else if app.supportsLaunch {
      step(1, .failed, "未发现调试接口，需要准备检查入口")
      state = .needsRestart
      message = "已识别前端引擎，但当前窗口未开放检查接口。可重新打开原应用，或另开使用独立网页配置的检查实例；登录状态取决于应用，可能需要重新登录。"
      capture.status = "等待准备检查入口 · \(app.name)"
    } else {
      step(1, .failed, "未发现 HTML 接口，可使用原生控件采集或截图")
      state = .unsupported
      message =
        "尚未发现「\(app.name)」的 HTML 接口。可以使用原生控件或区域截图采集。如果这是你的 WKWebView / Flutter 项目，也可在 Debug 构建中接入 DomScanBridge 后读取 DOM。"
      capture.status = "已选窗口，尚未接入 HTML · \(app.name)"
    }
  }

  // Open a separate profile instead of restarting or changing the user's current session.
  // Modern Chromium may refuse debugging on its default profile.
  func openInspectionInstance() async {
    guard let app = selectedApplication, app.supportsLaunch, !busy, !capture.busy else { return }
    let key = SHA256.hash(data: Data(app.bundleURL.standardizedFileURL.path.utf8))
      .prefix(12).map { String(format: "%02x", $0) }.joined()
    let profile = inspectionRoot.appendingPathComponent(key, isDirectory: true)
    refreshApplications()
    if let existing = applications.first(where: { candidate in
      guard candidate.bundleURL.standardizedFileURL == app.bundleURL.standardizedFileURL,
        let pid = candidate.processID, let argv = ProcessDiscovery.arguments(for: pid) else { return false }
      return argv.contains("--user-data-dir=" + profile.path)
    }) {
      await select(existing)
      inspectionProfile = profile
      if state == .needsRestart {
        message = "独立检查实例正在运行，但接口尚不可用。请正常关闭该独立实例后重试。"
      }
      return
    }
    busy = true
    defer { busy = false }
    state = .launching
    beginDiagnostics(engine: "Chromium")
    step(0, .success, "已识别 Chromium 引擎")
    step(1, .running, "等待独立实例开放本机调试接口")
    message = "正在打开独立检查实例，原应用继续运行…"
    await capture.disconnect()
    capture.targets = []
    capture.error = nil
    do {
      try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
      inspectionProfile = profile
      try await launch(app, originalArguments: [app.bundleURL.path,
        "--user-data-dir=" + profile.path, "--no-first-run", "--no-default-browser-check"])
      message = capture.connected
        ? "独立检查实例已接入；这里使用单独的网页配置，登录状态可能不同。"
        : "独立检查实例已打开，请选择其中的前端窗口。原应用继续运行。"
    } catch {
      state = .failed
      failure = .launch
      step(capture.targets.isEmpty ? 1 : 3, .failed, "独立实例未能完成连接，请查看错误提示")
      message = "独立检查实例接入失败：\(error.localizedDescription)"
    }
  }

  private func findEndpoint(_ pid: pid_t) async -> String? {
    let ports = await Task.detached { ProcessDiscovery.listeningPorts(for: pid) }.value
    portDiagnostics = ports.isEmpty ? ["监听端口：未发现 TCP 监听端口，或系统不允许读取进程端口"]
      : ["监听端口：\(ports.map(String.init).joined(separator: ", "))；最多探测前 24 个"]
    return await withTaskGroup(of: (String?, String).self) { group in
      for port in ports.prefix(24) {
        group.addTask {
          let address = "http://127.0.0.1:\(port)"
          do {
            let version = try await LocalEndpoint.json("/json/version", base: URL(string: address)!, timeout: 0.8)
            guard let socket = version["webSocketDebuggerUrl"] as? String else {
              return (nil, "端口 \(port)：版本响应缺少浏览器 WebSocket 地址")
            }
            guard (try? LocalEndpoint.validate(socket, websocket: true)) != nil else {
              return (nil, "端口 \(port)：WebSocket 地址未通过本机连接校验")
            }
            return (address, "端口 \(port)：CDP 版本与本机 WebSocket 地址校验通过")
          } catch {
            let nsError = error as NSError
            return (nil, "端口 \(port)：\(Task.isCancelled ? "已取消探测" : "请求或协议检查失败")（\(nsError.domain) \(nsError.code)）")
          }
        }
      }
      for await (endpoint, detail) in group {
        portDiagnostics.append(detail)
        if let endpoint {
          group.cancelAll()
          return endpoint
        }
      }
      return nil
    }
  }

  private func attach(_ endpoint: String, preferredTitle: String) async {
    diagnosticEndpoint = endpoint
    diagnosticEngine = "Chromium / CDP"
    step(1, .success, "已发现有效的本机 CDP 接口")
    step(2, .running, "读取前端页面列表")
    capture.endpoint = endpoint
    await capture.discover()
    guard capture.error == nil else {
      state = .failed
      failure = .connection
      step(2, .failed, "接口已发现，但读取页面列表失败")
      message = "检查接口暂时无法连接。\(capture.error ?? "")"
      return
    }
    state = .ready
    step(2, .success, "发现 \(capture.targets.count) 个前端页面")
    message = "已找到 \(capture.targets.count) 个前端窗口。"
    let available = capture.targets.filter { !$0.isPlaceholder }
    let matched = preferredTitle.isEmpty ? nil : available.first { $0.title == preferredTitle }
    if let target = matched ?? (available.count == 1 ? available.first : nil) {
      step(3, .running, "正在连接页面并安装拾取脚本")
      await capture.connect(target)
      recordConnectionResult()
      if capture.connected {
        message = "连接就绪，可以开始拾取。"
      } else {
        state = .failed
        failure = .connection
        message = "窗口接入失败。\(capture.error ?? "请选择其他窗口或重试。")"
      }
    }
  }

  func requestRestart() {
    guard let app = selectedApplication, app.supportsLaunch, !busy, !capture.busy else { return }
    let alert = NSAlert()
    alert.messageText = "重新打开「\(app.name)」并连接？"
    alert.informativeText = "应用将正常退出并重新打开，请先保存未保存的内容。若出现应用自己的保存提示，请处理后继续。选择器会保留原启动参数，并自动准备本机连接。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "重新打开并连接")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { await restartConfirmed() }
  }

  // Only call after the in-app restart confirmation; tests use a disposable host.
  func restartConfirmed() async {
    guard let app = selectedApplication, app.supportsLaunch, !busy else { return }
    busy = true
    defer { busy = false }
    beginDiagnostics(engine: "Chromium")
    step(0, .success, "已识别 Chromium 引擎")
    step(1, .running, "重新打开应用并等待本机调试接口")
    do {
      state = .launching
      message = "正在为「\(app.name)」准备连接…"
      var original: [String] = selectedLaunchArguments ?? [app.bundleURL.path]
      if let pid = app.processID, let running = NSRunningApplication(processIdentifier: pid),
        !running.isTerminated
      {
        guard running.bundleURL?.standardizedFileURL == app.bundleURL.standardizedFileURL else {
          throw SelectorError.message("应用进程已变化，请重新选择目标应用。")
        }
        guard let saved = ProcessDiscovery.arguments(for: pid) ?? selectedLaunchArguments,
          !saved.isEmpty
        else {
          throw SelectorError.message("无法保留应用原来的启动配置。请先正常退出应用，再通过“启动应用…”选择它。")
        }
        original = saved
        await capture.disconnect()
        guard running.terminate() else { throw SelectorError.message("应用未接受退出请求，请处理保存提示后重试。") }
        for _ in 0..<150 {
          if running.isTerminated { break }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard running.isTerminated else { throw SelectorError.message("应用尚未退出。请先处理它的保存提示，再重试。") }
      }
      try await launch(app, originalArguments: original)
    } catch {
      state = .failed
      failure = .launch
      step(capture.targets.isEmpty ? 1 : 3, .failed, "重新打开后未能完成连接，请查看错误提示")
      message = error.localizedDescription
    }
  }

  private func launch(_ app: DesktopApplication, originalArguments: [String]) async throws {
    let port = try ProcessDiscovery.availablePort()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ProcessDiscovery.launchArguments(from: originalArguments, port: port)
    selectedLaunchArguments = [app.bundleURL.path] + configuration.arguments
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
      NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: configuration) {
        running, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let running {
          continuation.resume(returning: running)
        } else {
          continuation.resume(throwing: SelectorError.message("应用启动失败。"))
        }
      }
    }
    refreshApplications()
    selectedApplication =
      applications.first { $0.processID == running.processIdentifier }
      ?? DesktopApplication(
        processID: running.processIdentifier, name: app.name, bundleURL: app.bundleURL,
        icon: app.icon,
        supportsLaunch: true, windows: [])
    let deadline = Date().addingTimeInterval(40)
    var discoveredEndpoint: String?
    while Date() < deadline {
      guard !running.isTerminated else { throw SelectorError.message("应用启动后退出了，请重新选择。") }
      if discoveredEndpoint == nil {
        discoveredEndpoint = await findEndpoint(running.processIdentifier)
      }
      if let endpoint = discoveredEndpoint {
        await attach(endpoint, preferredTitle: preferredTitle)
        if capture.connected || capture.targets.filter({ !$0.isPlaceholder }).count > 1 { return }
        state = .launching
        message = "应用已打开，正在等待前端窗口…"
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    if discoveredEndpoint != nil {
      throw SelectorError.message("应用已打开，但前端窗口尚未就绪。请稍后点击“重新尝试连接”。")
    }
    throw SelectorError.message("应用未开放元素读取入口。部分发布版会禁用此功能，选择器无法强制开启。")
  }

  func chooseApplicationToLaunch() {
    guard !busy, !capture.busy else { return }
    let panel = NSOpenPanel()
    panel.title = "选择要连接的桌面应用"
    panel.prompt = "选择应用"
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    refreshApplications()
    if let running = applications.first(where: {
      $0.bundleURL.standardizedFileURL == url.standardizedFileURL
    }) {
      Task { await select(running) }
      return
    }
    let app = DesktopApplication(
      processID: nil, name: url.deletingPathExtension().lastPathComponent,
      bundleURL: url, icon: NSWorkspace.shared.icon(forFile: url.path),
      supportsLaunch: DesktopApplication.hasChromiumEngine(url), windows: [])
    Task {
      await select(app)
      guard app.supportsLaunch else { return }
      busy = true
      state = .launching
      message = "正在启动「\(app.name)」…"
      defer { busy = false }
      do { try await launch(app, originalArguments: [url.path]) } catch {
        state = .failed
        failure = .launch
        message = error.localizedDescription
      }
    }
  }
}
