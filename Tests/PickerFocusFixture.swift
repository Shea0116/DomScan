import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var activations = 0
  let label = NSTextField(labelWithString: "激活次数：0")
  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(contentRect: CGRect(x: 80, y: 180, width: 620, height: 370),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "DomScan · Focus Fixture"
    window.isReleasedWhenClosed = false
    window.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.66, alpha: 1)
    let heading = NSTextField(labelWithString: "窗口选择与取消测试")
    heading.font = .systemFont(ofSize: 26, weight: .semibold)
    heading.frame = CGRect(x: 35, y: 260, width: 550, height: 45)
    label.frame = CGRect(x: 35, y: 210, width: 550, height: 35)
    let detail = NSTextField(labelWithString: "此测试窗口没有 HTML 入口。选中后应返回选择器并明确提示。")
    detail.frame = CGRect(x: 35, y: 150, width: 550, height: 45)
    window.contentView?.addSubview(heading)
    window.contentView?.addSubview(label)
    window.contentView?.addSubview(detail)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    activations += 1; label.stringValue = "激活次数：\(activations)"
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct FocusFixture {
  static func main() {
    let app = NSApplication.shared
    let delegate = FixtureDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
  }
}
