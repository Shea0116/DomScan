import AppKit
import ApplicationServices
import ScreenCaptureKit

enum NativeCapture {
  static func accessibilitySnapshot(at point: CGPoint, pid: pid_t) throws -> [String: Any] {
    guard AXIsProcessTrusted() else {
      throw SelectorError.message("需要辅助功能权限。请在系统设置中允许 DomScan，再重试点选原生控件。")
    }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.3)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
      let element = hit else {
      throw SelectorError.message("这个位置没有提供可读取的辅助功能控件。可以改用框选截图。")
    }
    var owner: pid_t = 0
    guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
      throw SelectorError.message("控件不属于选中的应用，请重新选择。")
    }
    AXUIElementSetMessagingTimeout(element, 0.3)
    func attribute(_ key: String) -> CFTypeRef? {
      var value: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    // Read descriptive metadata only. Input values, selected text and secure field contents are excluded.
    var attributes: [String: String] = [:]
    for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
      kAXHelpAttribute, kAXIdentifierAttribute] {
      if let value = attribute(key) as? String, !value.isEmpty {
        attributes[key] = String(value.prefix(1024))
      }
    }
    let role = attributes[kAXRoleAttribute] ?? "AXElement"
    let name = attributes[kAXTitleAttribute] ?? attributes[kAXDescriptionAttribute] ?? role
    var position = CGPoint.zero
    var size = CGSize.zero
    guard let rawPosition = attribute(kAXPositionAttribute),
      CFGetTypeID(rawPosition) == AXValueGetTypeID(),
      AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
      let rawSize = attribute(kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID(),
      AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
      position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0 else {
      throw SelectorError.message("控件未提供位置或尺寸。可以改用框选截图。")
    }
    return ["captureSource": CaptureSource.accessibility.rawValue, "token": UUID().uuidString,
      "tag": role, "name": name, "attributes": attributes,
      "selector": attributes[kAXIdentifierAttribute] ?? "\(role) · \(name)",
      "bounds": ["x": position.x, "y": position.y, "width": size.width, "height": size.height],
      "coordinateSpace": "global screen points, top-left origin",
      "limitations": "辅助功能元数据，不包含 DOM、CSS、源码映射或输入框当前值。定位描述不保证唯一。"]
  }

  static func screenshot(_ selection: DesktopSelection) async throws -> [String: Any] {
    guard CGPreflightScreenCaptureAccess() else {
      throw SelectorError.message("需要屏幕录制权限。请在系统设置中允许 DomScan，再重试框选截图。")
    }
    guard let region = selection.region, region.width >= 4, region.height >= 4 else {
      throw SelectorError.message("截图区域太小，请重新框选。")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: {
      $0.windowID == CGWindowID(selection.window.id)
        && $0.owningApplication?.processID == selection.window.processID
    }) else { throw SelectorError.message("目标窗口已关闭或不再可见，请重新选择。") }
    let clipped = region.intersection(window.frame)
    guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else {
      throw SelectorError.message("截图区域已离开目标窗口，请重新框选。")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    // Capture only this window, then crop in pixel coordinates. This avoids sourceRect's
    // display/window coordinate differences and keeps the selected region independent of shadows.
    configuration.ignoreShadowsSingleWindow = true
    let scale = min(2, 2048 / max(clipped.width, clipped.height),
      4096 / max(window.frame.width, window.frame.height))
    configuration.width = max(1, Int((window.frame.width * scale).rounded()))
    configuration.height = max(1, Int((window.frame.height * scale).rounded()))
    configuration.showsCursor = false
    let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    let xScale = CGFloat(fullImage.width) / window.frame.width
    let yScale = CGFloat(fullImage.height) / window.frame.height
    var pixels = CGRect(x: (clipped.minX - window.frame.minX) * xScale,
      y: (clipped.minY - window.frame.minY) * yScale,
      width: clipped.width * xScale, height: clipped.height * yScale).integral
      .intersection(CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height))
    pixels.size.width = min(pixels.width, 2048)
    pixels.size.height = min(pixels.height, 2048)
    guard !pixels.isEmpty, let image = fullImage.cropping(to: pixels) else {
      throw SelectorError.message("无法裁剪目标区域，请重新框选。")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw SelectorError.message("无法生成 PNG 图像，请重新框选。")
    }
    return ["captureSource": CaptureSource.screenshot.rawValue, "token": UUID().uuidString,
      "tag": "region", "name": "框选截图", "selector": "手动框选区域",
      "bounds": ["x": clipped.minX, "y": clipped.minY, "width": clipped.width, "height": clipped.height],
      "pixelWidth": image.width, "pixelHeight": image.height, "imagePNGBase64": png.base64EncodedString(),
      "coordinateSpace": "global screen points, top-left origin",
      "limitations": "选定窗口的区域截图，不包含 DOM、CSS、OCR 文本或源码映射。"]
  }

  static func requestAccessibilityPermission() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }
  static func requestScreenPermission() { _ = CGRequestScreenCaptureAccess() }
}
