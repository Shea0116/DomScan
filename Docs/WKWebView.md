# DomScan 的 WKWebView 支持

WKWebView 需要目标项目在 Debug 构建中接入 DomScanBridge。它读取真实 DOM、计算样式和每个 frame 的 HTML，支持同源、跨域、嵌套和新建 iframe。接入后，从 DomScan 的应用列表或屏幕窗口选择应用，无需填写端口或改变原启动方式。

macOS 的 Safari Web Inspector 调试通道不向普通第三方工具开放。`isInspectable = true` 只开启 Safari 检查，不能代替 DomScanBridge。任意未接入桥接的第三方 WKWebView 应用仍无法自动读取。

## Swift / AppKit 项目

在 Xcode 中用 Add Local Package 添加此仓库的 `Bridge` 文件夹，并把 `DomScanBridge` 产品加入应用 target。发布版 DomScan 也随附这个文件夹，位于应用包 `Contents/Resources/DomScanBridge`。

```swift
import DomScanBridge

let webView = WKWebView(frame: .zero)
#if DEBUG
if #available(macOS 11.0, *) {
  DomScanBridge.shared.attach(to: webView) // 放在首次 load 之前
}
#endif
webView.load(URLRequest(url: url))
```

所有调用均在主线程。桥接运行需要 macOS 11+；兼容更低部署目标的项目需保留上述 availability 判断。桥接不替换 navigationDelegate、uiDelegate、网页已有的脚本或消息通道。若应用启用了 App Sandbox，Debug entitlements 需要 `com.apple.security.network.server = true`，让桥接监听本机回环地址。Swift Debug 编译设置需包含 `DEBUG`；Release 下 start / attach 不启动服务。

## Flutter macOS 项目（包括 webview_flutter_wkwebview）

1. 打开 `macos/Runner.xcworkspace`，添加上述本地 Swift Package，链接到 Runner target。
2. 在 `macos/Runner/MainFlutterWindow.swift` 中 import 模块，并在 `awakeFromNib()` 的 `super.awakeFromNib()` 后启动观察：

```swift
import DomScanBridge

// awakeFromNib() 中
#if DEBUG
if #available(macOS 11.0, *) {
  DomScanBridge.shared.start() // 自动发现窗口视图树中新增的 WKWebView
}
#endif
```

3. 检查 `macos/Runner/DebugProfile.entitlements` 的 `com.apple.security.network.server` 为 true。标准 Flutter Debug 模板通常已有此项。不要把它添加到发布 entitlements。
4. 正常运行 `flutter run -d macos`。观察器每 0.5 秒扫描窗口视图树。网页首次加载若早于发现时机，在应用里**重新加载一次网页**，保证已存在的跨域 iframe 也注入脚本。之后导航和动态 iframe 会自动接入。
5. 在 DomScan 中选择应用，再选择所需 WKWebView。按 ⇧⌘Z 拾取；Shift 点击多选；Esc 结束。

不需要修改 Dart 的 WebViewController，也不依赖 `setInspectable`。页面重新加载不同于 Flutter 热重载；添加原生 Swift Package 后需要重新编译 macOS Runner。没有挂到窗口视图树的离屏 WebView 需要原生代码显式 `attach(to:)`。

## 行为与边界

- 仅作用于 WKWebView 中的 HTML；Flutter 原生控件不属于 DOM。
- 脚本运行于独立 WKContentWorld，逐 frame 注入，不从截图推测元素；支持开放 Shadow DOM。
- 公开 WKWebView API 不提供完整 frame 祖先树，导出的 `framePath` 仅包含当前 frame URL；独立 frame UUID 和 URL 仍可区分嵌套 frame。
- 页面已存在的跨域子 frame 不能通过公开 API 枚举补注入。原生项目在首次 load 之前 attach 可完整覆盖；自动观察模式需要重新加载一次网页。
- 断开连接会解除拾取；进程异常断线时脚本租约也会在约 7.5 秒内恢复正常输入。Esc 在当前 HTML frame 中生效并同步到所有已连接 frame。
- 只监听 `127.0.0.1` 随机端口。每次启动生成随机凭证，写入当前用户的私有临时目录（目录 0700、文件 0600）；DomScan 按所选应用 PID 读取凭证。仅允许固定拾取命令，不开放任意 JavaScript 执行接口。
- 桥接是开发工具，持有凭证的同一 macOS 用户可以读取已接入页面。不要在不需要调试的发布构建中启用。可读取 `DomScanBridge.shared.lastError` 排查桥接启动失败。
