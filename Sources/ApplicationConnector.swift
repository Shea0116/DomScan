import AppKit
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
  @Published var applications: [DesktopApplication] = []
  @Published var selectedApplication: DesktopApplication?
  @Published var state: State = .idle
  @Published var busy = false
  @Published var selectingWindow = false
  @Published private(set) var inspectionProfile: URL?
  @Published var message = "直接点选屏幕窗口，或从正在运行的应用中选择。"
  var onShowWindow: (() -> Void)?
  var onHideWindow: (() -> Void)?
  let capture: CaptureSession
  private var picker: DesktopWindowPicker?
  private var preferredTitle = ""
  private var selectedLaunchArguments: [String]?
  private var observers: [NSObjectProtocol] = []
  private let inspectionRoot: URL

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

  func refreshApplications() { applications = DesktopApplication.running() }

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
      onShowWindow?()
    }
    return true
  }

  func select(_ app: DesktopApplication, windowTitle: String = "") async {
    guard !busy, !capture.busy else { return }
    busy = true
    defer { busy = false }
    selectedApplication = app
    inspectionProfile = nil
    selectedLaunchArguments = nil
    preferredTitle = windowTitle
    state = .searching
    message = "正在连接「\(app.name)」…"
    await capture.disconnect()
    capture.status = "已选窗口，正在检查 HTML 接口 · \(app.name)"
    capture.error = nil
    capture.targets = []
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
      do {
        try await capture.discoverWebKit(bridge)
        state = .ready
        message = "已找到 \(capture.targets.count) 个 WKWebView。"
        let available = capture.targets.filter { !$0.isPlaceholder }
        let matched = windowTitle.isEmpty ? nil : available.first { $0.title == windowTitle }
        if let target = matched ?? (available.count == 1 ? available.first : nil) {
          await capture.connect(target)
          message = capture.connected ? "WKWebView 已接入，可以开始拾取。" : capture.error ?? "等待网页加载。"
        }
      } catch {
        state = .failed
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
      state = .needsRestart
      message = "已识别前端引擎，但当前窗口未开放检查接口。可重新打开原应用，或另开使用独立网页配置的检查实例；登录状态取决于应用，可能需要重新登录。"
      capture.status = "等待准备检查入口 · \(app.name)"
    } else {
      state = .unsupported
      message =
        "已选中「\(app.name)」的窗口，尚未发现 HTML 接口。Electron / Chromium 可开启调试入口；WKWebView 项目需要在 Debug 构建中接入 DomScanBridge，然后重新选择应用。仅开启 Safari 检查不足以连接 DomScan。"
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
      message = "独立检查实例接入失败：\(error.localizedDescription)"
    }
  }

  private func findEndpoint(_ pid: pid_t) async -> String? {
    let ports = await Task.detached { ProcessDiscovery.listeningPorts(for: pid) }.value
    return await withTaskGroup(of: String?.self) { group in
      for port in ports.prefix(24) {
        group.addTask {
          let address = "http://127.0.0.1:\(port)"
          guard let url = URL(string: address),
            let version = try? await LocalEndpoint.json("/json/version", base: url, timeout: 0.8),
            let socket = version["webSocketDebuggerUrl"] as? String,
            (try? LocalEndpoint.validate(socket, websocket: true)) != nil
          else { return nil }
          return address
        }
      }
      for await endpoint in group {
        if let endpoint {
          group.cancelAll()
          return endpoint
        }
      }
      return nil
    }
  }

  private func attach(_ endpoint: String, preferredTitle: String) async {
    capture.endpoint = endpoint
    await capture.discover()
    guard capture.error == nil else {
      state = .failed
      message = "连接暂时不可用，请重试。"
      return
    }
    state = .ready
    message = "已找到 \(capture.targets.count) 个前端窗口。"
    let available = capture.targets.filter { !$0.isPlaceholder }
    let matched = preferredTitle.isEmpty ? nil : available.first { $0.title == preferredTitle }
    if let target = matched ?? (available.count == 1 ? available.first : nil) {
      await capture.connect(target)
      if capture.connected {
        message = "连接就绪，可以开始拾取。"
      } else {
        state = .failed
        message = "窗口接入失败，请选择其他窗口或重试。"
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
    selectedApplication = app
    guard app.supportsLaunch else {
      state = .unsupported
      message = "当前还未支持这个应用的前端引擎。"
      return
    }
    Task {
      busy = true
      state = .launching
      message = "正在启动「\(app.name)」…"
      defer { busy = false }
      do { try await launch(app, originalArguments: [url.path]) } catch {
        state = .failed
        message = error.localizedDescription
      }
    }
  }
}
