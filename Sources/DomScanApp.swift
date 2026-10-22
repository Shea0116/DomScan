import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var shared: AppDelegate!
  var store: CaptureSession!
  var connector: ApplicationConnector!
  private var item: NSStatusItem?
  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var terminating = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.shared = self
    let source =
      Bundle.main.url(forResource: "picker", withExtension: "js").flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
      } ?? ""
    store = CaptureSession(source: source)
    connector = ApplicationConnector(capture: store)
    connector.onShowWindow = { [weak self] in self?.showWindow() }
    connector.onHideWindow = {
      NSApp.windows.first(where: { $0.title == "DomScan" })?.orderOut(nil)
    }
    store.endpoint =
      UserDefaults.standard.string(forKey: "debugEndpoint") ?? "http://127.0.0.1:9222"
    store.onPickModeChanged = { [weak self] picking in
      self?.item?.button?.image = NSImage(
        systemSymbolName: picking ? "scope" : "cursorarrow.and.square.on.square.dashed",
        accessibilityDescription: "DomScan")
    }
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item?.button?.image = NSImage(
      systemSymbolName: "cursorarrow.and.square.on.square.dashed",
      accessibilityDescription: "DomScan")
    let menu = NSMenu()
    menu.addItem(withTitle: "打开 DomScan", action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(withTitle: "点选应用窗口…", action: #selector(pickWindow), keyEquivalent: "")
    menu.addItem(withTitle: "取消窗口选择", action: #selector(cancelWindowPicking), keyEquivalent: "")
    menu.addItem(withTitle: "开始 / 暂停拾取  ⌘⇧S", action: #selector(togglePicking), keyEquivalent: "")
    menu.addItem(withTitle: "复制已选元素", action: #selector(copyElements), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
    for entry in menu.items { entry.target = self }
    item?.menu = menu
    installHotKey()
    if source.isEmpty { store.error = "未找到选择器资源，请重新构建应用。" }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { notification in
      guard let window = notification.object as? NSWindow, window.title == "DomScan" else {
        return
      }
      window.isReleasedWhenClosed = false
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateNow }
    terminating = true
    connector?.cancelWindowPickingIfActive()
    Task {
      await store?.disconnect()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    // A dead target should never keep quitting blocked indefinitely.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  @objc func showWindow() {
    guard !terminating else { return }
    if connector?.cancelWindowPickingIfActive() == true { return }
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0.title == "DomScan" })?.makeKeyAndOrderFront(nil)
  }
  @objc func togglePicking() {
    if connector.cancelWindowPickingIfActive() { return }
    guard !store.busy else { return }
    guard store.connected else {
      connector.pickWindow()
      return
    }
    Task {
      let enable = !store.picking
      await store.setPicking(enable)
      if enable {
        await store.activateTarget()
        connector.activateSelectedApplication()
        NSApp.hide(nil)
      }
    }
  }
  @objc func pickWindow() { connector.pickWindow() }
  @objc func cancelWindowPicking() { connector.cancelWindowPickingIfActive() }
  @objc func copyElements() {
    guard !store.elements.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(store.exportMarkdown(), forType: .string)
    store.status = "已复制 \(store.elements.count) 个元素的上下文"
  }
  @objc func quit() { NSApp.terminate(nil) }
  private func installHotKey() {
    let callback: EventHandlerUPP = { _, event, _ in
      guard let event else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      guard
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
        id.signature == 0x4453_4C43, id.id == 1
      else { return OSStatus(eventNotHandledErr) }
      DispatchQueue.main.async { AppDelegate.shared?.togglePicking() }
      return noErr
    }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event, nil, &eventHandler)
    let result = RegisterEventHotKey(
      UInt32(kVK_ANSI_S), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4453_4C43, id: 1),
      GetApplicationEventTarget(), 0, &hotKey)
    if result != noErr { store.status = "全局快捷键被占用，可使用菜单栏开始拾取" }
  }
}

@main
struct DomScanApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  var body: some Scene {
    Window("DomScan", id: "main") {
      RootContainer().frame(minWidth: 1060, minHeight: 700).preferredColorScheme(.dark)
    }.defaultSize(width: 1260, height: 820)
      .commands {
        CommandGroup(replacing: .newItem) {}
      }
  }
}

struct RootContainer: View {
  @State private var store: CaptureSession?
  var body: some View {
    Group {
      if let store {
        MainView(store: store, connector: AppDelegate.shared.connector)
      } else {
        ProgressView().task {
          for _ in 0..<50 {
            if let ready = AppDelegate.shared?.store {
              store = ready
              return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
          }
        }
      }
    }
  }
}

enum Theme {
  static let base = Color(red: 0.055, green: 0.065, blue: 0.09)
  static let panel = Color(red: 0.085, green: 0.10, blue: 0.135)
  static let raised = Color(red: 0.115, green: 0.13, blue: 0.17)
  static let accent = Color(red: 0.65, green: 0.53, blue: 1)
  static let mint = Color(red: 0.32, green: 0.85, blue: 0.73)
}

struct MainView: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  @State private var tab = "详情"
  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.5)
      HStack(spacing: 0) {
        sidebar.frame(width: 255)
        Divider().opacity(0.5)
        selectionList.frame(width: 315)
        Divider().opacity(0.5)
        inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider().opacity(0.5)
      footer
    }.background(Theme.base).tint(Theme.accent)
  }
  private var header: some View {
    HStack(spacing: 13) {
      if let logoURL = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
        let logo = NSImage(contentsOf: logoURL) {
        Image(nsImage: logo).resizable().interpolation(.high).frame(width: 45, height: 45)
      } else {
        Image(systemName: "scope").font(.system(size: 28)).foregroundStyle(Theme.accent)
          .frame(width: 45, height: 45)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("DomScan").font(.system(size: 19, weight: .semibold))
        Text("指向界面，带走上下文").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(store.connected ? Theme.mint : .gray).frame(width: 6, height: 6)
        Text(store.connected ? "已接入" : "未连接").font(.system(size: 11))
      }
      .padding(.horizontal, 11).padding(.vertical, 7).background(Theme.raised, in: Capsule())
      Button {
        connector.pickWindow()
      } label: {
        Label("点选窗口", systemImage: "macwindow").padding(.horizontal, 6).padding(.vertical, 5)
      }.disabled(connector.busy || store.busy)
      Button {
        AppDelegate.shared.togglePicking()
      } label: {
        Label(
          store.picking ? "暂停拾取" : "开始拾取",
          systemImage: store.picking ? "pause.fill" : "cursorarrow.rays"
        )
        .padding(.horizontal, 8).padding(.vertical, 5)
      }.buttonStyle(.borderedProminent).disabled(!store.connected || store.busy || connector.busy)
        .help(
          "⌘⇧S · 全局开始或暂停")
    }.padding(.horizontal, 25).padding(.vertical, 17).background(Theme.panel)
  }
  private var sidebar: some View {
    ConnectionSidebar(store: store, connector: connector)
  }
  private var selectionList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        sectionLabel("02", "已选元素")
        Spacer()
        Text("\(store.elements.count)").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Theme.mint)
      }.padding(20)
      if store.elements.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: "cursorarrow.and.square.on.square.dashed").font(
            .system(size: 38, weight: .ultraLight)
          ).foregroundStyle(Theme.accent.opacity(0.6))
          Text("从一个真实元素开始").font(.system(size: 13, weight: .medium))
          Text("点选屏幕窗口，或从左侧选择应用\n连接后按 ⌘⇧S 拾取元素").font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 9) {
            ForEach(Array(store.elements.enumerated()), id: \.element.id) { index, element in
              Button {
                store.focusedID = element.id
              } label: {
                VStack(alignment: .leading, spacing: 9) {
                  HStack {
                    Text(String(format: "%02d", index + 1)).font(
                      .system(size: 10, design: .monospaced)
                    ).foregroundStyle(.secondary)
                    Text("<\(element.tag)>").font(
                      .system(size: 11, weight: .medium, design: .monospaced)
                    ).foregroundStyle(Theme.mint)
                    Spacer()
                    if element.stale {
                      Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                  }
                  Text(element.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                  Text(element.selector).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
                  HStack(spacing: 5) {
                    Image(systemName: "rectangle.inset.filled")
                    Text(URL(string: element.frameURL)?.host ?? "local frame").lineLimit(1)
                    Spacer()
                    if !element.note.isEmpty {
                      Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
                    }
                  }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    store.focusedID == element.id ? Theme.accent.opacity(0.10) : Theme.panel,
                    in: RoundedRectangle(cornerRadius: 10)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(
                      store.focusedID == element.id
                        ? Theme.accent.opacity(0.6) : .white.opacity(0.06), lineWidth: 1))
              }.buttonStyle(.plain).contextMenu { Button("移除") { store.remove(element.id) } }
            }
          }.padding(.horizontal, 17).padding(.bottom, 15)
        }
      }
      Divider().opacity(0.4)
      HStack {
        Button("清空") { store.clear() }.disabled(store.elements.isEmpty)
        Spacer()
        Button {
          Task { await store.refresh() }
        } label: {
          Label("更新", systemImage: "arrow.clockwise")
        }.disabled(!store.connected || store.elements.isEmpty)
      }.font(.system(size: 11)).padding(17)
    }
  }
  private var inspector: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        sectionLabel("03", "元素上下文")
        Spacer()
        Picker("查看", selection: $tab) {
          Text("详情").tag("详情")
          Text("导出预览").tag("导出预览")
        }.pickerStyle(.segmented).frame(width: 155)
      }.padding(20)
      if tab == "导出预览" {
        ScrollView {
          Text(store.exportMarkdown()).font(.system(size: 11, design: .monospaced)).textSelection(
            .enabled
          ).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
      } else if let element = store.elements.first(where: { $0.id == store.focusedID })
        ?? store.elements.first
      {
        ElementInspector(store: store, element: element)
      } else if connector.state == .needsRestart {
        VStack(alignment: .leading, spacing: 18) {
          Label("需要准备检查入口", systemImage: "macwindow.badge.plus")
            .font(.system(size: 23, weight: .medium)).foregroundStyle(Theme.accent)
          Text(connector.message).font(.system(size: 13)).lineSpacing(6)
          Button("打开独立检查实例") {
            Task { await connector.openInspectionInstance() }
          }.buttonStyle(.borderedProminent).disabled(connector.busy)
          Text("在新实例中操作和拾取元素。原窗口继续运行；两者的网页登录状态可能不同。")
            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
          Button("重新打开原应用并连接…") { connector.requestRestart() }
            .disabled(connector.busy)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      } else if connector.state == .searching || connector.state == .launching {
        VStack(alignment: .leading, spacing: 18) {
          ProgressView().controlSize(.large)
          Text(connector.message).font(.system(size: 14)).lineSpacing(6)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      } else if connector.state == .ready && !store.connected {
        VStack(alignment: .leading, spacing: 18) {
          Label("选择前端窗口", systemImage: "macwindow")
            .font(.system(size: 23, weight: .medium)).foregroundStyle(Theme.accent)
          Text("应用包含多个前端窗口。请从左侧“选择前端窗口”中选择需要检查的界面。")
            .font(.system(size: 13)).lineSpacing(6)
          Text("窗口列表会自动更新。")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      } else if connector.state == .unsupported || connector.state == .failed {
        VStack(alignment: .leading, spacing: 18) {
          Label("尚未接入 HTML", systemImage: "exclamationmark.circle")
            .font(.system(size: 23, weight: .medium)).foregroundStyle(.orange)
          Text(connector.message).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
          Text("请点选其他应用窗口，或从左侧选择应用。")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      } else {
        emptyInspector
      }
      Spacer(minLength: 0)
      Divider().opacity(0.4)
      HStack {
        Menu {
          Button("Markdown + JSON") { exportFiles() }
        } label: {
          Label("导出文件", systemImage: "square.and.arrow.up")
        }.menuStyle(.borderlessButton).frame(width: 110)
        Spacer()
        Button {
          AppDelegate.shared.copyElements()
        } label: {
          Label("复制上下文", systemImage: "doc.on.doc").padding(.horizontal, 7).padding(.vertical, 3)
        }.buttonStyle(.borderedProminent)
      }.disabled(store.elements.isEmpty).padding(17)
    }
  }
  private var emptyInspector: some View {
    VStack(alignment: .leading, spacing: 23) {
      Text("界面背后，\n是可以读懂的结构。").font(.system(size: 28, weight: .medium)).lineSpacing(8)
      Text("读取真实 DOM、计算样式和 frame 路径，\n把需要修改的部分准确交给 AI。").font(.system(size: 13)).foregroundStyle(
        .secondary
      ).lineSpacing(7)
      HStack(spacing: 8) {
        pill("DOM", icon: "chevron.left.forwardslash.chevron.right")
        pill("CSS", icon: "paintpalette")
        pill("iframe", icon: "square.stack.3d.up")
      }
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 4)
      VStack(alignment: .leading, spacing: 16) {
        feature("scope", "悬停定位", "直接命中真实 HTML 元素")
        feature("square.stack", "穿过 frame", "独立连接跨域及嵌套 iframe")
        feature("text.bubble", "带上要求", "为每个元素添加修改说明")
      }
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
  private var footer: some View {
    HStack(spacing: 9) {
      Circle().fill(store.picking ? Theme.accent : store.connected ? Theme.mint : .gray).frame(
        width: 5, height: 5)
      Text(store.status).lineLimit(1)
      Spacer()
      if !store.frameWarnings.isEmpty {
        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(
          store.frameWarnings.joined(separator: "\n"))
      }
      Text("\(store.worlds.count) frames").font(.system(size: 10, design: .monospaced))
      Text("本地采集").padding(.leading, 8)
    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(
      .vertical, 11
    ).background(Theme.panel)
  }
  private func sectionLabel(_ number: String, _ title: String) -> some View {
    HStack(spacing: 8) {
      Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.accent)
      Text(title).font(.system(size: 12, weight: .semibold))
    }
  }
  private func shortcut(_ key: String, _ title: String) -> some View {
    HStack {
      Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary)
      Spacer()
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }
  private func pill(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon).font(.system(size: 10, design: .monospaced)).foregroundStyle(
      Theme.accent
    ).padding(.horizontal, 10).padding(.vertical, 7).background(
      Theme.accent.opacity(0.09), in: Capsule())
  }
  private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
    HStack(spacing: 13) {
      Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 12, weight: .medium))
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
  private func exportFiles() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "selection.md"
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try store.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
      let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
      // A separate save panel avoids silently replacing an existing sidecar.
      if FileManager.default.fileExists(atPath: jsonURL.path) {
        let alert = NSAlert()
        alert.messageText = "JSON 文件已存在"
        alert.informativeText = "Markdown 已保存。选择新的文件名保存 JSON。"
        alert.runModal()
        let jsonPanel = NSSavePanel()
        jsonPanel.nameFieldStringValue = "selection-context.json"
        jsonPanel.allowedContentTypes = [.json]
        if jsonPanel.runModal() == .OK, let alternate = jsonPanel.url {
          try store.exportJSON().write(to: alternate, options: .atomic)
        }
      } else {
        try store.exportJSON().write(to: jsonURL, options: .atomic)
      }
      store.status = "上下文已导出"
    } catch { store.error = "导出失败：\(error.localizedDescription)" }
  }
}

struct ElementInspector: View {
  @ObservedObject var store: CaptureSession
  let element: SelectedElement
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 21) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 8) {
            Text("<\(element.tag)>").font(.system(size: 12, design: .monospaced)).foregroundStyle(
              Theme.mint)
            Text(element.name).font(.system(size: 20, weight: .medium)).lineLimit(3)
          }
          Spacer()
          Button {
            store.remove(element.id)
          } label: {
            Image(systemName: "trash")
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        if element.stale {
          Label("页面已更新或连接已关闭，请重新选择以获取最新信息。", systemImage: "exclamationmark.circle").font(
            .system(size: 11)
          ).foregroundStyle(.orange)
        }
        HStack(spacing: 6) {
          nav("父级", direction: "parent", icon: "arrow.up")
          nav("子级", direction: "child", icon: "arrow.down")
          nav("上一个", direction: "previous", icon: "arrow.left")
          nav("下一个", direction: "next", icon: "arrow.right")
        }.disabled(element.stale || !store.connected)
        VStack(alignment: .leading, spacing: 9) {
          Text("你想修改什么？").font(.system(size: 12, weight: .semibold))
          TextEditor(
            text: Binding(
              get: { store.elements.first(where: { $0.id == element.id })?.note ?? "" },
              set: { store.note(element.id, $0) })
          ).font(.system(size: 12)).scrollContentBackground(.hidden).padding(9).frame(height: 85)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        block("元素定位", text: element.selector)
        block("Frame", text: element.frameURL + "\n" + element.world.frameID)
        if let rect = element.snapshot["bounds"] as? [String: Any] {
          HStack(spacing: 20) {
            metric("宽", rect["width"])
            metric("高", rect["height"])
            metric("X", rect["x"])
            metric("Y", rect["y"])
          }
        }
        if let text = element.snapshot["text"] as? String, !text.isEmpty { block("文本", text: text) }
        if let css = element.snapshot["styles"] as? [String: String] {
          block(
            "计算样式", text: css.keys.sorted().map { "\($0): \(css[$0]!);" }.joined(separator: "\n"))
        }
        block("HTML", text: element.snapshot["html"] as? String ?? "")
      }.padding(.horizontal, 23).padding(.bottom, 25)
    }.id(element.id)
  }
  private func nav(_ title: String, direction: String, icon: String) -> some View {
    Button {
      Task { await store.navigate(element, direction: direction) }
    } label: {
      Label(title, systemImage: icon).font(.system(size: 10))
    }.controlSize(.small)
  }
  private func block(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
          Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
  }
  private func metric(_ title: String, _ value: Any?) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(String(format: "%.1f", (value as? NSNumber)?.doubleValue ?? 0)).font(
        .system(size: 12, design: .monospaced))
    }
  }
}
