import AppKit
import Carbon

struct DesktopSelection {
  let window: DesktopWindow
  let point: CGPoint
  let region: CGRect?
  static func clippedRegion(from start: CGPoint, to end: CGPoint, within window: CGRect) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(window)
  }
}

@MainActor
final class DesktopWindowPicker {
  private var panels: [NSPanel] = []
  private var keyMonitor: Any?
  private var deactivationObserver: NSObjectProtocol?
  private var workspaceObserver: NSObjectProtocol?
  private var escapeHotKey: EventHotKeyRef?
  private var escapeHandler: EventHandlerRef?
  private var expiryTimer: Timer?
  private var completion: ((DesktopSelection?) -> Void)?
  private(set) var escapeHotKeyRegistered = false
  var isActive: Bool { completion != nil }

  func start(timeout: TimeInterval = 30, completion: @escaping (DesktopWindow?) -> Void) {
    startSelection(timeout: timeout, processID: nil, region: false) { completion($0?.window) }
  }

  func startElement(processID: pid_t, region: Bool, timeout: TimeInterval = 30,
    completion: @escaping (DesktopSelection?) -> Void) {
    startSelection(timeout: timeout, processID: processID, region: region, completion: completion)
  }

  private func startSelection(timeout: TimeInterval, processID: pid_t?, region: Bool,
    completion: @escaping (DesktopSelection?) -> Void) {
    guard !isActive else { return }
    self.completion = completion
    let windows = DesktopApplication.windowsOnScreen().filter { processID == nil || $0.processID == processID }
    guard !windows.isEmpty else {
      finish(nil)
      return
    }
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    let mouse = NSEvent.mouseLocation
    var focusedPanel: NSPanel?
    for screen in NSScreen.screens {
      let panel = PickingPanel(
        contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      panel.title = processID == nil ? "选择应用窗口 · 第 1 步" : region ? "框选截图区域" : "点选原生控件"
      panel.level = .screenSaver
      panel.isOpaque = false
      panel.isReleasedWhenClosed = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.hidesOnDeactivate = false
      panel.becomesKeyOnlyIfNeeded = false
      panel.acceptsMouseMovedEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let origin = CGPoint(x: screen.frame.minX, y: primaryTop - screen.frame.maxY)
      let view = WindowPickingView(
        frame: CGRect(origin: .zero, size: screen.frame.size), windows: windows,
        screenOrigin: origin, primaryTop: primaryTop, elementMode: processID != nil, regionMode: region)
      view.remainingSeconds = max(1, Int(ceil(timeout)))
      view.choose = { [weak self] chosen in
        DispatchQueue.main.async { self?.finish(chosen) }
      }
      panel.contentView = view
      panel.makeFirstResponder(view)
      panels.append(panel)
      panel.orderFrontRegardless()
      if screen.frame.contains(mouse) { focusedPanel = panel }
    }
    if let panel = focusedPanel ?? panels.first {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(panel.contentView)
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      DispatchQueue.main.async { self?.cancel() }
      return nil
    }
    registerEscape()
    // Switching to another application must never leave an input-blocking panel behind.
    deactivationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { self?.cancel() }
    }
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
      DispatchQueue.main.async { self?.cancel() }
    }
    let deadline = Date().addingTimeInterval(max(0.1, timeout))
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isActive else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
          self.cancel()
          return
        }
        for panel in self.panels {
          (panel.contentView as? WindowPickingView)?.remainingSeconds = Int(ceil(remaining))
        }
      }
    }
    expiryTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func registerEscape() {
    let callback: EventHandlerUPP = { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      guard
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
        id.signature == 0x4453_504B, id.id == 2
      else { return OSStatus(eventNotHandledErr) }
      let picker = Unmanaged<DesktopWindowPicker>.fromOpaque(context).takeUnretainedValue()
      DispatchQueue.main.async { picker.cancel() }
      return noErr
    }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, context, &escapeHandler)
        == noErr
    else { return }
    escapeHotKeyRegistered =
      RegisterEventHotKey(
        UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4453_504B, id: 2),
        GetApplicationEventTarget(), 0, &escapeHotKey) == noErr
  }

  func cancel() { finish(nil) }

  private func finish(_ window: DesktopSelection?) {
    guard let callback = completion else { return }
    completion = nil
    expiryTimer?.invalidate()
    expiryTimer = nil
    if let deactivationObserver {
      NotificationCenter.default.removeObserver(deactivationObserver)
      self.deactivationObserver = nil
    }
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
      self.workspaceObserver = nil
    }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    if let escapeHotKey {
      UnregisterEventHotKey(escapeHotKey)
      self.escapeHotKey = nil
    }
    if let escapeHandler {
      RemoveEventHandler(escapeHandler)
      self.escapeHandler = nil
    }
    escapeHotKeyRegistered = false
    for panel in panels {
      panel.orderOut(nil)
      panel.close()
    }
    panels = []
    callback(window)
  }
}

private final class PickingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

private final class PickerCancelButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class WindowPickingView: NSView {
  let windows: [DesktopWindow]
  let screenOrigin: CGPoint
  let primaryTop: CGFloat
  var choose: ((DesktopSelection?) -> Void)?
  let elementMode: Bool
  let regionMode: Bool
  private var dragStart: CGPoint?
  private var dragWindow: DesktopWindow?
  private var dragRect: CGRect?
  var remainingSeconds = 30 { didSet { if oldValue != remainingSeconds { needsDisplay = true } } }
  private var hovered: DesktopWindow?
  private var tracking: NSTrackingArea?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  init(frame: CGRect, windows: [DesktopWindow], screenOrigin: CGPoint, primaryTop: CGFloat,
    elementMode: Bool = false, regionMode: Bool = false) {
    self.elementMode = elementMode
    self.regionMode = regionMode
    self.windows = windows
    self.screenOrigin = screenOrigin
    self.primaryTop = primaryTop
    super.init(frame: frame)
    let mouse = NSEvent.mouseLocation
    hovered = windows.first { $0.bounds.contains(CGPoint(x: mouse.x, y: primaryTop - mouse.y)) }
    let cancel = PickerCancelButton(
      title: "取消选择  Esc", target: self, action: #selector(cancelClicked))
    cancel.frame = CGRect(x: max(15, frame.width - 162), y: 18, width: 144, height: 36)
    cancel.bezelStyle = .rounded
    cancel.font = .systemFont(ofSize: 13, weight: .semibold)
    cancel.keyEquivalent = "\u{1b}"
    cancel.autoresizingMask = [.minXMargin, .maxYMargin]
    cancel.setAccessibilityIdentifier("window-picker-cancel")
    addSubview(cancel)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let next = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(next)
    tracking = next
  }
  private func hitWindow(_ event: NSEvent) -> DesktopWindow? {
    let local = convert(event.locationInWindow, from: nil)
    let global = CGPoint(x: screenOrigin.x + local.x, y: screenOrigin.y + local.y)
    return windows.first { $0.bounds.contains(global) }
  }
  override func mouseMoved(with event: NSEvent) {
    hovered = hitWindow(event)
    needsDisplay = true
  }
  private func screenPoint(_ event: NSEvent) -> CGPoint {
    let local = convert(event.locationInWindow, from: nil)
    return CGPoint(x: screenOrigin.x + local.x, y: screenOrigin.y + local.y)
  }
  override func mouseDown(with event: NSEvent) {
    guard let selected = hitWindow(event) else { return }
    let point = screenPoint(event)
    if regionMode {
      dragStart = point
      dragWindow = selected
    } else {
      choose?(DesktopSelection(window: selected, point: point, region: nil))
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStart, let window = dragWindow else { return }
    let end = screenPoint(event)
    dragRect = DesktopSelection.clippedRegion(from: start, to: end, within: window.bounds)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    guard regionMode, let start = dragStart, let window = dragWindow else { return }
    mouseDragged(with: event)
    if let rect = dragRect, rect.width >= 4, rect.height >= 4 {
      choose?(DesktopSelection(window: window, point: start, region: rect))
    } else {
      dragStart = nil; dragWindow = nil; dragRect = nil; needsDisplay = true
    }
  }
  override func rightMouseDown(with event: NSEvent) { choose?(nil) }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { choose?(nil) } else { super.keyDown(with: event) }
  }
  override func cancelOperation(_ sender: Any?) { choose?(nil) }
  @objc private func cancelClicked() { choose?(nil) }

  override func draw(_ dirtyRect: NSRect) {
    let selected = hovered
    let dim = NSBezierPath(rect: bounds)
    var localRect: CGRect?
    if let selected {
      let rect = (dragRect ?? selected.bounds).offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).insetBy(
        dx: 2, dy: 2)
      localRect = rect
      dim.append(NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9))
      dim.windingRule = .evenOdd
    }
    NSColor.black.withAlphaComponent(0.16).setFill()
    dim.fill()
    if let rect = localRect {
      let outline = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
      outline.lineWidth = 3
      NSColor.systemPurple.setStroke()
      outline.stroke()
    }
    let text = regionMode ? "拖动框选截图区域 · 仅截取目标窗口"
      : elementMode ? "点击目标应用中的原生控件"
      : selected.map { "第 1 步 · 选择「\($0.owner)」的窗口" } ?? "第 1 步 · 点击目标应用的窗口"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white,
    ]
    let width = min(
      bounds.width - 40, max(360, (text as NSString).size(withAttributes: attrs).width + 36))
    let box = CGRect(x: max(15, (bounds.width - width) / 2), y: 18, width: width, height: 64)
    NSColor(calibratedRed: 0.12, green: 0.08, blue: 0.20, alpha: 0.97).setFill()
    NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
    (text as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
    let subtitle = elementMode
      ? "\(regionMode ? "图像来源" : "辅助功能来源") · Esc / 右键取消 · \(remainingSeconds) 秒后退出"
      : "选中后检测 HTML 接口 · \(remainingSeconds) 秒后自动退出"
    (subtitle as NSString).draw(
      at: CGPoint(x: box.minX + 16, y: box.minY + 36),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.white.withAlphaComponent(0.75),
      ])
  }
}
