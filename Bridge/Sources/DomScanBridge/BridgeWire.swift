import Foundation
import Network

enum BridgeFailure: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// A bounded, newline-delimited JSON channel. All state lives on the main actor.
@MainActor
final class BridgeWire {
  let connection: NWConnection
  var onMessage: (([String: Any]) -> Void)?
  var onClose: (() -> Void)?
  private var buffer = Data()
  private var closed = false
  private var serial = 0
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var deadlines: [Int: Task<Void, Never>] = [:]

  init(_ connection: NWConnection) { self.connection = connection }
  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        if case .failed = state { self?.close() }
        if case .cancelled = state { self?.close() }
      }
    }
    connection.start(queue: .main)
    receive()
  }
  func send(_ object: [String: Any]) {
    guard !closed, var data = try? JSONSerialization.data(withJSONObject: object),
      data.count < 524_288 else { return }
    data.append(10)
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      if error != nil { Task { @MainActor in self?.close() } }
    })
  }
  func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
    guard !closed else { throw BridgeFailure.message("WKWebView 桥接已断开。") }
    serial += 1
    let id = serial
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      deadlines[id] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard !Task.isCancelled else { return }
        self?.finish(id, .failure(BridgeFailure.message("WKWebView 桥接响应超时。")))
      }
      send(["id": id, "method": method, "params": params])
    }
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        if let data { self.buffer.append(data) }
        guard self.buffer.count <= 524_288 else { self.close(); return }
        while let newline = self.buffer.firstIndex(of: 10) {
          let line = self.buffer.prefix(upTo: newline)
          self.buffer.removeSubrange(...newline)
          guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            self.close(); return
          }
          if let reply = message["reply"] as? Int {
            if let error = message["error"] as? String {
              self.finish(reply, .failure(BridgeFailure.message(error)))
            } else { self.finish(reply, .success(message["result"] as? [String: Any] ?? [:])) }
          } else { self.onMessage?(message) }
        }
        if done || error != nil { self.close() } else { self.receive() }
      }
    }
  }
  private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
    deadlines.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }
  func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    for id in Array(pending.keys) { finish(id, .failure(BridgeFailure.message("WKWebView 桥接已断开。"))) }
    buffer = Data()
    let callback = onClose
    onClose = nil
    onMessage = nil
    callback?()
  }
}
