import Foundation
@testable import Network
import SecureStore
import Session
import XCTest

/// 本地假服务：URLProtocol 桩。不连任何真实地址；基址用 .invalid。
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case json(status: Int, headers: [String: String], body: String)
        case error(URLError.Code)
        case redirect(to: String)
        /// 先不回应（模拟还在等连接 / 服务端还没回），直到测试 `release(id, with:)`；取消时 `wasStopped(id)` 为 true。
        case hold(String)
    }

    /// 被 hold 住的请求：所在线程的 run loop 与协议实例（回应在原线程上交付）。
    private final class Held: @unchecked Sendable {
        let stub: StubURLProtocol
        let runLoop: CFRunLoop

        init(stub: StubURLProtocol, runLoop: CFRunLoop) {
            self.stub = stub
            self.runLoop = runLoop
        }
    }

    private nonisolated(unsafe) static var held: [String: Held] = [:]
    private nonisolated(unsafe) static var stopped: Set<String> = []
    private nonisolated(unsafe) static var heldWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var holdId: String?

    /// 等到 id 这个请求被 hold 住（已到达假服务）。
    static func waitUntilHeld(_ id: String) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if held[id] != nil || stopped.contains(id) {
                    return true
                }
                heldWaiters[id, default: []].append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    static func wasStopped(_ id: String) -> Bool {
        lock.withLock { stopped.contains(id) }
    }

    /// 回应一个被 hold 住的请求（在它原来的线程上交付）。
    static func release(_ id: String, with reply: Reply) {
        guard let entry = lock.withLock({ held.removeValue(forKey: id) }) else {
            return
        }
        CFRunLoopPerformBlock(entry.runLoop, CFRunLoopMode.commonModes.rawValue) {
            entry.stub.deliver(reply)
        }
        CFRunLoopWakeUp(entry.runLoop)
    }

    struct Recorded {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: String

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            recorded = []
            held = [:]
            stopped = []
            heldWaiters = [:]
        }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(path: String) -> [Recorded] {
        requests.filter { $0.path == path }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            path: url.path(percentEncoded: true),
            query: url.query(percentEncoded: true),
            headers: request.allHTTPHeaderFields ?? [:],
            body: String(data: body, encoding: .utf8) ?? ""
        )
        let reply: Reply? = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry)
        }
        if case let .hold(id) = reply {
            holdId = id
            let waiters: [CheckedContinuation<Void, Never>] = Self.lock.withLock {
                Self.held[id] = Held(stub: self, runLoop: CFRunLoopGetCurrent())
                return Self.heldWaiters.removeValue(forKey: id) ?? []
            }
            waiters.forEach { $0.resume() }
            return
        }
        deliver(reply ?? .error(.cannotConnectToHost))
    }

    private func deliver(_ reply: Reply) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case .hold:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        case let .json(status, headers, text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .error(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .redirect(target):
            let location = URL(string: target, relativeTo: url)?.absoluteURL ?? url
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString]
            )
            var next = URLRequest(url: location)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response ?? URLResponse())
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html>moved</html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard let id = holdId else {
            return
        }
        let waiters: [CheckedContinuation<Void, Never>] = Self.lock.withLock {
            Self.held[id] = nil
            Self.stopped.insert(id)
            return Self.heldWaiters.removeValue(forKey: id) ?? []
        }
        waiters.forEach { $0.resume() }
    }
}

/// 外壳响应。
func envelope(_ code: Int, data: String = "null", msg: String = "", trace: String = "trace-0001-abcdef") -> String {
    "{\"code\":\(code),\"msg\":\"\(msg)\",\"data\":\(data),\"trace_id\":\"\(trace)\"}"
}

func ok(_ data: String = "{}", headers: [String: String] = [:]) -> StubURLProtocol.Reply {
    .json(status: 200, headers: headers, body: envelope(0, data: data))
}

func fail(_ code: Int, status: Int = 400, data: String = "{}", headers: [String: String] = [:]) -> StubURLProtocol
    .Reply {
    .json(status: status, headers: headers, body: envelope(code, data: data))
}

/// 刷新接口的契约示例形状（TokenPairResponse：令牌在 data）。
func refreshData(access: String, refresh: String = "refresh-2", scope: String = "full") -> String {
    "{\"access_token\":\"\(access)\",\"access_expires_at\":\"2026-10-02T13:30:00+08:00\","
        + "\"refresh_token\":\"\(refresh)\",\"refresh_expires_at\":\"2026-11-01T11:30:00+08:00\","
        + "\"session_scope\":\"\(scope)\"}"
}

/// 登录接口的契约示例形状（LoginResponse：令牌在 data.tokens）。
func loginData(access: String, scope: String, user: String = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a61") -> String {
    "{\"user_id\":\"\(user)\",\"is_new_user\":true,\"tokens\":\(refreshData(access: access, scope: scope)),"
        + "\"invite_bind\":{\"result\":\"bound\",\"code\":null}}"
}

struct TestDevice: DeviceCredentials {
    var deviceId: String? = "device-fixture"
    var installSecret: String? = "test-only.install.device-a"
}

/// 测试可变的网络状态。
final class TestState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NetworkContext(
        privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
        update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.couli.invalid")
    )

    private var reads = 0
    private var hook: (@Sendable (Int) -> Void)?

    var context: NetworkContext {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// 每次管线读状态时先调用（参数为设置本钩子之后第几次读取，从 1 开始），用来在管线的两步之间改状态。
    var onRead: (@Sendable (Int) -> Void)? {
        get { lock.withLock { hook } }
        set {
            lock.withLock {
                hook = newValue
                reads = 0
            }
        }
    }

    /// 管线读状态的入口。
    func read() -> NetworkContext {
        let (count, current) = lock.withLock { () -> (Int, (@Sendable (Int) -> Void)?) in
            reads += 1
            return (reads, hook)
        }
        current?(count)
        return context
    }

    func set(
        privacy: String? = nil,
        settled: Bool? = nil,
        readable: Bool? = nil,
        update: String? = nil
    ) {
        let current = context
        context = NetworkContext(
            privacy: privacy ?? current.privacy,
            environmentSettled: settled ?? current.environmentSettled,
            credentialsReadable: readable ?? current.credentialsReadable,
            update: update ?? current.update,
            apiBaseURL: current.apiBaseURL
        )
    }
}
