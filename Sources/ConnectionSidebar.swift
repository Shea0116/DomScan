import AppKit
import SwiftUI

struct ConnectionSidebar: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  @State private var search = ""
  @State private var showAdvanced = false
  @State private var showAllApplications = false
  var disabled: Bool { store.busy || connector.busy }
  var filtered: [DesktopApplication] {
    connector.applications.filter {
      (showAllApplications || connector.capability(for: $0) != .unknown)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
    }.sorted {
      let left = connector.capability(for: $0).rawValue
      let right = connector.capability(for: $1).rawValue
      return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text("01").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.accent)
        Text("选择桌面应用").font(.system(size: 12, weight: .semibold))
        Spacer()
        Button {
          connector.refreshApplications()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain).help("刷新正在运行的应用").disabled(disabled)
      }
      Button {
        connector.pickWindow()
      } label: {
        Label("在屏幕上点选窗口", systemImage: "viewfinder")
          .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
      }.buttonStyle(.borderedProminent).disabled(disabled)
      Button {
        connector.chooseApplicationToLaunch()
      } label: {
        Label("启动应用…", systemImage: "plus.app").frame(maxWidth: .infinity)
      }.disabled(disabled)

      if let app = connector.selectedApplication {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            appIcon(app, size: 30)
            VStack(alignment: .leading, spacing: 3) {
              Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
              Text(store.connected ? "HTML 已连接" : "窗口已选中").font(.system(size: 10)).foregroundStyle(
                store.connected ? Theme.mint : .secondary)
            }
            Spacer()
            if connector.busy { ProgressView().controlSize(.small) }
          }
          Text(connector.sidebarMessage)
          .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .help(connector.guidanceMessage)
          if store.selectedTarget?.needsReload == true {
            Text("桥接在网页加载后接入。请在目标应用里重新加载一次网页，让已有的跨域 iframe 也就绪。")
              .font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(4)
          }
          ConnectionActions(store: store, connector: connector)
          if let profile = connector.inspectionProfile {
            Text("独立检查配置").font(.system(size: 10)).foregroundStyle(Theme.mint)
              .help(profile.path)
          }
          if store.connected {
            Button("断开连接") { Task { await connector.disconnect() } }.font(.system(size: 11))
              .disabled(
                disabled)
          }
        }.padding(12).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      }

      if !store.targets.isEmpty {
        Text("选择前端窗口").font(.system(size: 11, weight: .semibold))
        ScrollView {
          VStack(spacing: 6) {
            ForEach(store.targets) { target in
              Button {
                Task { await store.connect(target); connector.recordConnectionResult() }
              } label: {
                HStack(alignment: .top, spacing: 7) {
                  Image(systemName: "macwindow").foregroundStyle(Theme.accent)
                  Text(target.title.isEmpty ? "未命名窗口" : target.title).lineLimit(3)
                  Spacer(minLength: 0)
                  if store.selectedTarget?.id == target.id && store.connected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                  }
                }.font(.system(size: 11)).padding(10).frame(
                  maxWidth: .infinity, alignment: .leading
                )
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
              }.buttonStyle(.plain).disabled(disabled)
            }
          }
        }.frame(maxHeight: 160)
      }

      HStack {
        Text("正在运行").font(.system(size: 11, weight: .semibold))
        Spacer()
        Text("\(connector.applications.count)").font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Picker("应用范围", selection: $showAllApplications) {
        Text("有接入线索").tag(false)
        Text("全部应用").tag(true)
      }.pickerStyle(.segmented)
      TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder).font(.system(size: 11))
      ScrollView {
        LazyVStack(spacing: 5) {
          if filtered.isEmpty {
            Text(showAllApplications ? "没有匹配的应用。" : "没有匹配的接入线索。可切换“全部应用”或点选窗口继续检测。")
              .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(9)
          }
          ForEach(filtered) { app in
            Button {
              Task { await connector.select(app) }
            } label: {
              HStack(spacing: 9) {
                appIcon(app, size: 25)
                VStack(alignment: .leading, spacing: 3) {
                  Text(app.name).font(.system(size: 12)).lineLimit(1)
                  Text(app.windows.isEmpty ? "正在运行" : "\(app.windows.count) 个可见窗口")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                  Text(connector.selectedApplication?.id == app.id && store.connected
                    ? "HTML 已连接"
                    : connector.selectedApplication?.id == app.id && connector.state == .unsupported
                      ? "尚未发现 HTML 接口" : connector.capability(for: app).label)
                    .font(.system(size: 9)).foregroundStyle(
                      connector.capability(for: app) == .unknown ? Color.secondary : Theme.mint)
                    .help("引擎或桥接线索不代表一定可连接；选择后会实际检查 HTML 接口。")
                }
                Spacer(minLength: 0)
                if connector.selectedApplication?.id == app.id {
                  Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Theme.mint)
                }
              }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  connector.selectedApplication?.id == app.id
                    ? Theme.accent.opacity(0.12) : Theme.raised.opacity(0.45),
                  in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(disabled)
          }
        }
      }

      DisclosureGroup("高级连接", isExpanded: $showAdvanced) {
        VStack(alignment: .leading, spacing: 8) {
          TextField("本机连接地址", text: $store.endpoint).textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced)).disabled(store.connected || disabled)
          Button("手动发现窗口") {
            Task { await connector.discoverManually() }
          }.disabled(disabled)
          if let error = store.error {
            Text(error).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
          }
          ConnectionDiagnosticsView(store: store, connector: connector)
        }.padding(.top, 8)
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Text("⇧⌘Z 开始 / 暂停 · Esc 退出").font(.system(size: 9)).foregroundStyle(.secondary)
      Text("LOCAL FIRST  /  v0.5.0").font(.system(size: 9, design: .monospaced)).foregroundStyle(
        .secondary)
    }.padding(16).background(Theme.panel.opacity(0.65))
      .onAppear { connector.refreshApplications() }
  }

  @ViewBuilder private func appIcon(_ app: DesktopApplication, size: CGFloat) -> some View {
    if let icon = app.icon {
      Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
    } else {
      Image(systemName: "app").resizable().frame(width: size, height: size).foregroundStyle(
        .secondary)
    }
  }
}

struct ConnectionDiagnosticsView: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  @State private var expanded = true
  var body: some View {
    DisclosureGroup("连接诊断", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        Text("最近一次连接尝试 · 当前 \(store.connected ? "HTML 已连接" : "HTML 未连接")")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        ForEach(connector.diagnosticSteps) { step in
          HStack(alignment: .top, spacing: 8) {
            if step.status == .running { ProgressView().controlSize(.mini) }
            else {
              Image(systemName: step.status == .success ? "checkmark.circle.fill"
                : step.status == .failed ? "exclamationmark.circle" : "circle")
                .foregroundStyle(step.status == .success ? Theme.mint
                  : step.status == .failed ? Color.orange : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
              Text("\(step.title) · \(step.status.rawValue)")
              if !step.detail.isEmpty { Text(step.detail).foregroundStyle(.secondary) }
            }
          }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        if connector.diagnosticSteps.isEmpty { Text("选择应用后记录连接过程。").font(.system(size: 11)) }
        Button("复制诊断信息") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(connector.diagnosticReport(), forType: .string)
          store.status = "已复制连接诊断信息"
        }
        .disabled(connector.diagnosticSteps.isEmpty)
        Text("包含引擎、端口与连接阶段；不包含采集内容和桥接凭据。")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.top, 8)
    }.font(.system(size: 11))
  }
}

struct NativeCaptureActions: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("其他采集方式").font(.system(size: 12, weight: .semibold))
      Button("点选原生控件（辅助功能）") { connector.captureNative(region: false) }
      Button("框选截图区域") { connector.captureNative(region: true) }
      Button("权限与采集说明") { connector.openNativeGuide() }
      Text("原生控件提供名称、角色和屏幕位置；截图保存选定窗口的图像。两者均不提供 HTML、CSS 或源码映射。首次使用需允许对应系统权限。")
        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
    }.disabled(connector.selectedApplication?.processID == nil || connector.busy || store.busy || connector.selectingWindow)
  }
}

struct ConnectionActions: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if !store.connected && connector.offersInspectionInstance {
        Button("打开独立检查实例") { Task { await connector.openInspectionInstance() } }
          .buttonStyle(.borderedProminent)
        Text("使用单独网页配置，可能需重新登录；原应用继续运行。")
          .font(.system(size: 10)).foregroundStyle(.secondary)
        Button("重新打开原应用并连接…") { connector.requestRestart() }
      }
      if connector.offersRetry, let app = connector.selectedApplication {
        Button("重新尝试连接") { Task { await connector.select(app) } }
      }
      if !store.connected && connector.offersBridgeGuide {
        Button("WKWebView / Flutter 接入说明") { connector.openBridgeGuide() }
        Text("仅适用于可修改源码的项目；接入 Debug 桥接后重新选择应用。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.font(.system(size: 11)).disabled(store.busy || connector.busy)
  }
}
