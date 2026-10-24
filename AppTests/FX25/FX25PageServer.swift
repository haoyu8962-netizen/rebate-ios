import Foundation
import Network

/// 真实 WK 历史导航用的回环 HTTP 服务。只在测试进程内监听随机端口；不访问外部网络。
/// 可扣住指定路径的响应，明确制造 didStart 已到、didCommit 未到的窗口；也可同时扣住多条（beacon / keepalive）再一并放出。
final class FX25PageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "couli.test.fx25-pages")
    private let lock = NSLock()
    private var heldPaths: Set<String> = []
    private var heldConnections: [(connection: NWConnection, path: String?)] = []
    private var targets: [String] = []
    private var connections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<Void, Never>?

    var origin: String {
        "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"
    }

    var isHoldingResponse: Bool {
        lock.withLock { !heldConnections.isEmpty }
    }

    private let page: String
    private var counts: [String: Int] = [:]
    private var sentCounts: [String: Int] = [:]
    private var cookies: [String: String] = [:]

    /// 指定路径的响应带上 Set-Cookie（与 holdResponse 配合制造迟到的 Set-Cookie）。
    func setCookie(_ value: String, for path: String) {
        lock.withLock { cookies[path] = value }
    }

    /// 指定路径的响应已经整段交给网络层的次数。
    func responded(_ path: String) -> Int {
        lock.withLock { sentCounts[path, default: 0] }
    }

    func requests(_ path: String) -> Int {
        lock.withLock { counts[path, default: 0] }
    }

    /// 按到达顺序记录的请求目标（含查询串），取以 `prefix` 开头的。
    func targets(prefix: String) -> [String] {
        lock.withLock { targets.filter { $0.hasPrefix(prefix) } }
    }

    init(page: String) throws {
        self.page = page
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        await withCheckedContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready, .failed, .cancelled:
                    self?.finishStarting()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard listener.port != nil else { throw URLError(.cannotConnectToHost) }
    }

    func stop() {
        listener.cancel()
        let active = lock.withLock {
            defer {
                connections.removeAll()
                heldConnections = []
                heldPaths = []
            }
            return connections
        }
        active.forEach { $0.cancel() }
    }

    func holdResponse(for path: String) {
        holdResponses(for: [path])
    }

    /// 扣住这些路径（不含查询串）的每一个响应，直到 `releaseResponse()`。
    func holdResponses(for paths: Set<String>) {
        lock.withLock { heldPaths.formUnion(paths) }
    }

    /// 放出全部被扣住的响应，并停止扣留（之后到达的同路径请求立即响应）。
    func releaseResponse() {
        let held = lock.withLock {
            defer {
                heldConnections = []
                heldPaths = []
            }
            return heldConnections
        }
        for entry in held {
            respond(entry.connection, path: entry.path)
        }
    }

    private func finishStarting() {
        let continuation = lock.withLock {
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume()
    }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var received = buffered
            if let data {
                received.append(data)
            }
            guard received.count < 65536 else {
                connection.cancel()
                return
            }
            guard let text = String(bytes: received, encoding: .utf8) else {
                connection.cancel()
                return
            }
            guard text.contains("\r\n\r\n") else {
                if done {
                    connection.cancel()
                } else {
                    receiveRequest(connection, buffered: received)
                }
                return
            }
            let target = text.split(separator: " ").dropFirst().first.map(String.init)
            let path = target.map { String($0.split(separator: "?", maxSplits: 1).first ?? "") }
            let held = lock.withLock {
                counts[target ?? "", default: 0] += 1
                targets.append(target ?? "")
                guard let path, heldPaths.contains(path) else { return false }
                heldConnections.append((connection, path))
                return true
            }
            if !held {
                respond(connection, path: path)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String?) {
        let html = page
        let cookie = lock.withLock { path.flatMap { cookies[$0] } }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + (cookie.map { "Set-Cookie: \($0)\r\nCache-Control: no-store\r\n" }
                ?? "Cache-Control: private, max-age=600\r\n")
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.markSent(path)
            connection.cancel()
        })
    }

    private func markSent(_ path: String?) {
        lock.withLock { sentCounts[path ?? "", default: 0] += 1 }
    }
}
