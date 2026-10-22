import Darwin
import Foundation
import Network

struct WebKitEndpoint {
  let pid: Int32
  let port: UInt16
  let token: String

  static func find(pid: Int32, bundleURL: URL) -> WebKitEndpoint? {
    var roots = [FileManager.default.temporaryDirectory]
    if let bundleID = Bundle(url: bundleURL)?.bundleIdentifier,
      !bundleID.contains("/"), !bundleID.contains("..") {
      roots.append(FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(bundleID)/Data/tmp"))
    }
    for root in roots {
      let file = root.appendingPathComponent("io.github.shea0116.domscan/\(pid).json")
      let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { continue }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
        info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size < 4096 else { continue }
      var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
      guard read(fd, &bytes, bytes.count) == bytes.count,
        let row = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
        row["protocol"] as? Int == 1, row["pid"] as? Int == Int(pid),
        let port = row["port"] as? Int, (1...65535).contains(port),
        let token = row["token"] as? String, token.count >= 64, token.count < 200 else { continue }
      return WebKitEndpoint(pid: pid, port: UInt16(port), token: token)
    }
    return nil
  }
}

@MainActor
final class WebKitConnection {
  private var wire: BridgeWire?
  var onEvent: (([String: Any]) -> Void)?
  var onDisconnect: (() -> Void)?

  func open(_ endpoint: WebKitEndpoint) async throws {
    close()
    let wire = BridgeWire(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp))
    self.wire = wire
    wire.onMessage = { [weak self] message in self?.onEvent?(message) }
    wire.onClose = { [weak self] in self?.onDisconnect?() }
    wire.start()
    let hello = try await wire.request("hello", ["protocol": 1, "pid": endpoint.pid, "token": endpoint.token])
    guard hello["protocol"] as? Int == 1, hello["pid"] as? Int == Int(endpoint.pid) else {
      close(); throw SelectorError.message("WKWebView 桥接身份校验失败。")
    }
  }
  func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
    guard let wire else { throw SelectorError.message("WKWebView 桥接尚未连接。") }
    return try await wire.request(method, params)
  }
  func close() {
    wire?.onClose = nil
    wire?.onMessage = nil
    wire?.close()
    wire = nil
  }
}
