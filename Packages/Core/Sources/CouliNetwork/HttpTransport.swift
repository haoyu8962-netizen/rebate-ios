import Foundation

/// 已决定好头与字节、待发出的一次请求。每次实际发送前由 ApiClient 重新组装（重新校验、重新组头、重新签名）。
struct PreparedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
}

/// 一次发送的结果（解包之前）。
enum TransportOutcome: Sendable {
    /// 收到 HTTP 响应（是否统一外壳由 ApiClient 判定；HTTP 状态码不决定成败）。
    case response(status: Int, headers: [String: String], body: Data)
    /// 超时、断连或被取消：没有响应。
    case failure(kind: String)
}

/// URLSession 发送（03 §4.2 中间件「发送」一步）。
///
/// - 不跟随重定向（`willPerformHTTPRedirection` 一律拒绝）：重定向目标不会绕过白名单与凭据检查，3xx 按没有统一外壳处理。
/// - 不用缓存、不存 Cookie、不等待联网；URLSession 不会因 503 / Retry-After 自动重发；
///   传输层自己不做任何重试（读接口的 1 次重试由 ApiClient 重新组装请求后发起）。
/// - 每个超时值一个会话（timeoutIntervalForRequest 与 timeoutIntervalForResource 都设成该值）。
/// - `cancelAll`：撤回同意、切换环境、清会话时取消全部在途任务。
final class HttpTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let kindTimeout = "timeout"
    static let kindDisconnect = "disconnect"
    static let kindNoEnvelope = "no_envelope"
    static let kindCancelled = "cancelled"

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var sessions: [Int64: URLSession] = [:]
    private var tasks: [Int: URLSessionTask] = [:]
    private var nextId = 0

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    private func session(timeoutMillis: Int64) -> URLSession {
        lock.withLock {
            if let existing = sessions[timeoutMillis] {
                return existing
            }
            let config = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
            let seconds = TimeInterval(timeoutMillis) / 1000
            config.timeoutIntervalForRequest = seconds
            config.timeoutIntervalForResource = seconds
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpShouldUsePipelining = false
            config.waitsForConnectivity = false
            let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            sessions[timeoutMillis] = created
            return created
        }
    }

    /// isCurrent 在登记任务的同一把锁里检查：请求已被作废（撤回同意等）就立即取消，不会漏过 `cancelAll`。
    func send(
        _ prepared: PreparedRequest,
        timeoutMillis: Int64,
        isCurrent: @escaping @Sendable () -> Bool
    ) async -> TransportOutcome {
        var request = URLRequest(url: prepared.url)
        request.httpMethod = prepared.method
        request.timeoutInterval = TimeInterval(timeoutMillis) / 1000
        request.httpShouldHandleCookies = false
        for (name, value) in prepared.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = prepared.body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let urlSession = session(timeoutMillis: timeoutMillis)
        let id: Int = lock.withLock {
            nextId += 1
            return nextId
        }
        let result = await withCheckedContinuation { continuation in
            let task = urlSession.dataTask(with: request) { data, response, error in
                continuation.resume(returning: Self.outcome(data: data, response: response, error: error))
            }
            let current = lock.withLock {
                tasks[id] = task
                return isCurrent()
            }
            if !current {
                // 先取消再启动：任务直接以 cancelled 结束，请求不会发出。
                task.cancel()
            }
            task.resume()
        }
        lock.withLock { tasks[id] = nil }
        return result
    }

    /// 取消全部在途任务（结果按 cancelled，没有统一外壳）。
    func cancelAll() {
        let running = lock.withLock { Array(tasks.values) }
        for task in running {
            task.cancel()
        }
    }

    private static func outcome(data: Data?, response: URLResponse?, error: Error?) -> TransportOutcome {
        if let error {
            let code = (error as? URLError)?.code
            switch code {
            case .timedOut?:
                return .failure(kind: kindTimeout)
            case .cancelled?:
                return .failure(kind: kindCancelled)
            default:
                return .failure(kind: kindDisconnect)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(kind: kindDisconnect)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String {
                headers[name] = "\(value)"
            }
        }
        return .response(status: http.statusCode, headers: headers, body: data ?? Data())
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 不跟随：重定向后的请求不再经过白名单、凭据与签名检查（三端统一）。
        completionHandler(nil)
    }
}
