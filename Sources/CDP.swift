import Foundation

enum SelectorError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

enum LocalEndpoint {
  static func validate(_ string: String, websocket: Bool = false) throws -> URL {
    guard let url = URL(string: string),
      let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
      (websocket ? ["ws", "wss"] : ["http"]).contains(url.scheme ?? ""),
      url.user == nil, url.password == nil
    else {
      throw SelectorError.message("请输入本机调试地址，例如 http://127.0.0.1:9222。")
    }
    return url
  }

  static func json(_ path: String, base: URL, timeout: TimeInterval = 5) async throws -> [String:
    Any]
  {
    let (data, response) = try await fetch(path, base: base, timeout: timeout)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw SelectorError.message("这个端口没有提供 Chromium 调试接口。")
    }
    return object
  }

  static func fetch(_ path: String, base: URL, timeout: TimeInterval = 5) async throws -> (
    Data, URLResponse
  ) {
    let url = URL(string: path, relativeTo: base)!.absoluteURL
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let config = URLSessionConfiguration.ephemeral
    let session = URLSession(
      configuration: config, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    return try await session.data(for: request)
  }
}

final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

struct DebugTarget: Identifiable {
  let id: String
  let title: String
  let url: String
  let type: String
  var isPlaceholder: Bool { url.isEmpty || url == "about:blank" }
  init?(_ json: [String: Any]) {
    guard let id = json["id"] as? String, let type = json["type"] as? String,
      type == "page" || type == "webview"
    else { return nil }
    self.id = id
    self.type = type
    title = json["title"] as? String ?? "未命名窗口"
    url = json["url"] as? String ?? ""
  }
}

@MainActor
final class CDPConnection {
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var receiveTask: Task<Void, Never>?
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  var onEvent: ((String, [String: Any], String?) -> Void)?
  var onDisconnect: ((Error) -> Void)?

  func open(_ url: URL) {
    close()
    let config = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: config)
    self.session = session
    let socket = session.webSocketTask(with: url)
    self.socket = socket
    socket.resume()
    receiveTask = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await socket.receive()
          guard !Task.isCancelled else { return }
          switch message {
          case .string(let value): self?.handle(Data(value.utf8))
          case .data(let data): self?.handle(data)
          @unknown default: break
          }
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.failPending(error)
        self?.onDisconnect?(error)
      }
    }
  }

  func request(_ method: String, _ params: [String: Any] = [:], sessionID: String? = nil)
    async throws -> [String: Any]
  {
    guard let socket else { throw SelectorError.message("调试连接尚未建立。") }
    nextID += 1
    let id = nextID
    var message: [String: Any] = ["id": id, "method": method, "params": params]
    if let sessionID { message["sessionId"] = sessionID }
    let data = try JSONSerialization.data(withJSONObject: message)
    let text = String(decoding: data, as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      timeouts[id] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard !Task.isCancelled else { return }
        self?.finish(id, .failure(SelectorError.message("调试接口响应超时：\(method)")))
      }
      Task { [weak self] in
        do { try await socket.send(.string(text)) } catch { self?.finish(id, .failure(error)) }
      }
    }
  }

  private func handle(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let id = json["id"] as? Int {
      if let error = json["error"] as? [String: Any] {
        finish(id, .failure(SelectorError.message(error["message"] as? String ?? "调试接口错误")))
      } else {
        finish(id, .success(json["result"] as? [String: Any] ?? [:]))
      }
    } else if let method = json["method"] as? String {
      onEvent?(method, json["params"] as? [String: Any] ?? [:], json["sessionId"] as? String)
    }
  }

  private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }
  private func failPending(_ error: Error) {
    for id in Array(pending.keys) { finish(id, .failure(error)) }
  }
  func close() {
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
    failPending(SelectorError.message("连接已关闭。"))
  }
}
