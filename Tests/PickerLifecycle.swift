import AppKit

@MainActor final class LifecycleDelegate: NSObject, NSApplicationDelegate {
  let picker = DesktopWindowPicker()
  var completed = false
  var failed = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    picker.start(timeout: 2) { [weak self] chosen in
      guard let self else { return }
      guard !self.failed else { exit(1) }
      self.completed = true
      let live = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("选择应用窗口") }
      guard chosen == nil, !self.picker.isActive, live.isEmpty else {
        print("FAIL lifecycle cleanup"); exit(1)
      }
      print("PASS picker timeout cancels without user input")
      print("PASS timeout removes every input-blocking panel")
      // Re-entry must work after cancellation, and cancellation must be idempotent.
      self.picker.start(timeout: 10) { chosen in
        guard chosen == nil else { print("FAIL unexpected selection"); exit(1) }
        print("PASS picker can be opened again after cleanup")
      }
      self.picker.cancel(); self.picker.cancel()
      guard !self.picker.isActive else { print("FAIL cancel"); exit(1) }
      print("PASS explicit cancellation is idempotent")
      let focusLossStart = Date()
      self.picker.start(timeout: 2) { chosen in
        let live = NSApp.windows.filter { $0.isVisible && $0.title.hasPrefix("选择应用窗口") }
        guard chosen == nil, !self.picker.isActive, live.isEmpty,
          Date().timeIntervalSince(focusLossStart) < 1 else {
          print("FAIL focus-loss cleanup"); exit(1)
        }
        print("PASS focus-loss notification removes the overlay")
        print("ALL PICKER LIFECYCLE CHECKS PASSED")
        exit(0)
      }
      NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    }
    guard picker.isActive else { print("FAIL no target windows"); exit(1) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      guard NSApp.keyWindow?.title.hasPrefix("选择应用窗口") == true,
        NSApp.keyWindow?.firstResponder is NSView else {
        self.failed = true
        print("FAIL picker not key window / first responder"); self.picker.cancel(); exit(1)
      }
      print("PASS picker owns a key window and first responder")
      guard self.picker.escapeHotKeyRegistered else {
        self.failed = true
        print("FAIL global Escape registration"); self.picker.cancel(); exit(1)
      }
      print("PASS global Escape registration")
    }
  }
}

@main struct PickerLifecycle {
  static func main() {
    let app = NSApplication.shared
    let delegate = LifecycleDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
  }
}
