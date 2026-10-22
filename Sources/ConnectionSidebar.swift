import AppKit
import SwiftUI

struct ConnectionSidebar: View {
  @ObservedObject var store: CaptureSession
  @ObservedObject var connector: ApplicationConnector
  @State private var search = ""
  @State private var showAdvanced = false
  var disabled: Bool { store.busy || connector.busy }
  var filtered: [DesktopApplication] {
    connector.applications.filter {
      search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
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
              Text(store.connected ? "已连接" : "已选择").font(.system(size: 10)).foregroundStyle(
                store.connected ? Theme.mint : .secondary)
            }
            Spacer()
            if connector.busy { ProgressView().controlSize(.small) }
          }
          Text(
            connector.state == .ready && !store.connected && store.selectedTarget != nil
              ? "连接已断开，可以重新尝试连接。" : connector.message
          )
          .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
          if store.selectedTarget?.needsReload == true {
            Text("桥接在网页加载后接入。请在目标应用里重新加载一次网页，让已有的跨域 iframe 也就绪。")
              .font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(4)
          }
          if connector.state == .needsRestart || (connector.state == .failed && app.supportsLaunch)
          {
            Button {
              Task { await connector.openInspectionInstance() }
            } label: {
              Label("打开独立检查实例", systemImage: "macwindow.badge.plus")
                .font(.system(size: 11)).frame(maxWidth: .infinity)
            }.disabled(disabled)
            Text("使用单独网页配置，可能需重新登录；原应用继续运行。")
              .font(.system(size: 10)).foregroundStyle(.secondary)
            Button {
              connector.requestRestart()
            } label: {
              Label("重新打开并连接", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11)).frame(maxWidth: .infinity)
            }.disabled(disabled)
          }
          if let profile = connector.inspectionProfile {
            Text("独立检查配置").font(.system(size: 10)).foregroundStyle(Theme.mint)
              .help(profile.path)
          }
          if store.connected {
            Button("断开连接") { Task { await connector.disconnect() } }.font(.system(size: 11))
              .disabled(
                disabled)
          } else if !connector.busy {
            Button("重新尝试连接") { Task { await connector.select(app) } }.font(.system(size: 11))
              .disabled(disabled)
          }
        }.padding(12).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      }

      if !store.targets.isEmpty {
        Text("选择前端窗口").font(.system(size: 11, weight: .semibold))
        ScrollView {
          VStack(spacing: 6) {
            ForEach(store.targets) { target in
              Button {
                Task { await store.connect(target) }
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
      TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder).font(.system(size: 11))
      ScrollView {
        LazyVStack(spacing: 5) {
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
                }
                Spacer(minLength: 0)
                if connector.selectedApplication?.id == app.id {
                  Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Theme.mint)
                } else if app.supportsLaunch {
                  Text("Chromium").font(.system(size: 8, design: .monospaced)).foregroundStyle(
                    Theme.mint).help("检测到前端引擎；能否读取 HTML 仍需连接后确认")
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
            Task {
              connector.selectedApplication = nil
              await store.discover()
              if let target = store.targets.first, store.targets.count == 1 {
                await store.connect(target)
              }
            }
          }.disabled(disabled)
          if let error = store.error {
            Text(error).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
          }
        }.padding(.top, 8)
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Text("⇧⌘Z 开始 / 暂停 · Esc 退出").font(.system(size: 9)).foregroundStyle(.secondary)
      Text("LOCAL FIRST  /  v0.4.0").font(.system(size: 9, design: .monospaced)).foregroundStyle(
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
