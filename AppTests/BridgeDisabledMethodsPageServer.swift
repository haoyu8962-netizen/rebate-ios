import Foundation
import Network

/// 真实 WK 历史导航用的回环 HTTP 服务。只在测试进程内监听随机端口；不访问外部网络。
/// 可扣住指定路径的响应，明确制造 didStart 已到、didCommit 未到的窗口。
final class DisabledMethodsPageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "couli.test.fx24-pages")
    private let lock = NSLock()
    private var heldPath: String?
    private var heldConnection: NWConnection?
    private var connections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<Void, Never>?

    var origin: String {
        "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"
    }

    var isHoldingResponse: Bool {
        lock.withLock { heldConnection != nil }
    }

    init() throws {
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
                heldConnection = nil
                heldPath = nil
            }
            return connections
        }
        active.forEach { $0.cancel() }
    }

    func holdResponse(for path: String) {
        lock.withLock { heldPath = path }
    }

    func releaseResponse() {
        let connection = lock.withLock {
            defer {
                heldConnection = nil
                heldPath = nil
            }
            return heldConnection
        }
        if let connection {
            respond(connection)
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
            let path = text.split(separator: " ").dropFirst().first.map(String.init)
            let held = lock.withLock {
                guard heldPath == path, heldConnection == nil else { return false }
                heldConnection = connection
                return true
            }
            if !held {
                respond(connection)
            }
        }
    }

    private func respond(_ connection: NWConnection) {
        let html = Self.page
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: private, max-age=600\r\nContent-Length: \(html.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + html
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let page = """
    <!doctype html><html><head><title>F-X-24 history</title></head><body><p>History probe</p><script>
    window.fx24Doc = {id: String(Math.random()), path: location.pathname, shows: 0, persisted: false};
    addEventListener('pageshow', event => {
      window.fx24Doc.shows += 1;
      window.fx24Doc.persisted = event.persisted;
    });
    addEventListener('pagehide', event => {
      sessionStorage.setItem('fx24.hide.' + location.pathname, JSON.stringify({
        id: window.fx24Doc.id, persisted: event.persisted,
        methods: window.__REBATE_BRIDGE__ ? window.__REBATE_BRIDGE__.methods : null
      }));
    });
    </script></body></html>
    """
}
