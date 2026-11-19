import Foundation

/// APP-13a-1-ios 写测：App13a1DeletionPipelineTests 的本地假服务与脚本（r3 由测试文件拆出）。
/// 本地假服务（URLProtocol）：按「方法 路径」脚本回答；可挂起后放行；可按超时结束（没有统一外壳）。记录方法、路径、请求体与请求头。
final class App13a1Stub: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case envelope(Int, String)
        case timeout
        case hold
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let body: String
        let headers: [String: String]
        let id: Int

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var held: [Int: App13a1Stub] = [:]
    private nonisolated(unsafe) static var next = 0
    private let stoppedLock = NSLock()
    private var stopped = false

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [App13a1Stub.self]
        return config
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
            held = [:]
            next = 0
        }
    }

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock { self.handler = handler }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    static var heldIds: [Int] {
        lock.withLock { held.keys.sorted() }
    }

    static func release(_ id: Int, with reply: Reply) {
        let target = lock.withLock { held.removeValue(forKey: id) }
        target?.answer(reply)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let entry: Recorded = Self.lock.withLock {
            Self.next += 1
            return Recorded(
                method: request.httpMethod ?? "GET", path: url.path, body: Self.body(request),
                headers: request.allHTTPHeaderFields ?? [:], id: Self.next
            )
        }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry) ?? .envelope(0, "{}")
        }
        if case .hold = reply {
            Self.lock.withLock { Self.held[entry.id] = self }
            return
        }
        answer(reply)
    }

    func answer(_ reply: Reply) {
        guard !stoppedLock.withLock({ stopped }) else { return }
        let url = request.url ?? URL(fileURLWithPath: "/")
        switch reply {
        case .timeout:
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case let .envelope(code, data):
            let text = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"stub-trace-0123456789ab\"}"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            break
        }
    }

    override func stopLoading() {
        stoppedLock.withLock { stopped = true }
    }

    private static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(bytes: data, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        var data = Data()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        stream.close()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// 按「方法 路径」排队的回答（用完重复最后一个）；没登记的：发码 / 验证给成功，其余 {}。
final class App13a1Script: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [App13a1Stub.Reply]] = [:]

    func on(_ key: String, _ replies: App13a1Stub.Reply...) {
        lock.withLock { queues[key] = replies }
    }

    func ok(_ key: String, _ data: String) {
        on(key, .envelope(0, data))
    }

    func reply(_ request: App13a1Stub.Recorded) -> App13a1Stub.Reply {
        let key = "\(request.method) \(request.path)"
        let scripted: App13a1Stub.Reply? = lock.withLock {
            guard var queue = queues[key], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            queues[key] = queue.isEmpty ? [first] : queue
            return first
        }
        if let scripted {
            return scripted
        }
        switch key {
        case "POST /v1/auth/sms-codes":
            return .envelope(0, "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        case "POST /v1/auth/step-up":
            return .envelope(
                0,
                "{\"step_up_token\":\"\(App13a1PipelineFixture.stepUpToken)\","
                    + "\"expire_at\":\"2099-01-01T00:05:00+08:00\"}"
            )
        default:
            return .envelope(0, "{}")
        }
    }
}
