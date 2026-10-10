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
    /// 只给测试用的观察 / 暂停点（FU-IOS-0711 R1-01），生产为 nil。见 `HttpTransportProbe`。
    /// 用单独的锁保存：`closeAll` 要在取传输锁之前读它（暂停点可能正持有传输锁）。
    private let probeLock = NSLock()
    private var probeStorage: HttpTransportProbe?
    private var probe: HttpTransportProbe? {
        probeLock.withLock { probeStorage }
    }

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    /// 测试注入（internal，只经 `@testable import` 可见）：须在发出任何请求之前设置。
    func installProbe(_ probe: HttpTransportProbe?) {
        probeLock.withLock { probeStorage = probe }
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
    /// 最终准入与启动（`task.resume`）在同一把锁里完成（FU-IOS-0711）：`closeAll` 也取这把锁推进作废世代，所以每个请求要么在
    /// 作废之前已经启动（随后被 `closeAll` 取消），要么准入时已看到新世代、不启动——不存在「准入通过、作废开始、之后才启动」的交错。
    /// `cancelWithTask` 为真时（桥调用，APP-04 三端共性第 45 条）：调用方的 Task 被取消（桥调用到截止时间、页面关闭）
    /// 就取消对应的网络任务，不等它自己超时；登记前已取消的直接不发。
    func send(
        _ prepared: PreparedRequest,
        timeoutMillis: Int64,
        cancelWithTask: Bool = false,
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
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = urlSession.dataTask(with: request) { data, response, error in
                    continuation.resume(returning: Self.outcome(data: data, response: response, error: error))
                }
                lock.withLock {
                    tasks[id] = task
                    let admitted = isCurrent() && !(cancelWithTask && Task.isCancelled)
                    probe?.admitted(admitted)
                    if !admitted {
                        // 先取消再启动：任务直接以 cancelled 结束，请求不会发出。
                        task.cancel()
                    }
                    probe?.starting(admitted)
                    task.resume()
                }
            }
        } onCancel: {
            guard cancelWithTask else { return }
            lock.withLock { tasks[id] }?.cancel()
        }
        lock.withLock { tasks[id] = nil }
        return result
    }

    /// 取消全部在途任务（结果按 cancelled，没有统一外壳）。
    func cancelAll() {
        closeAll {}
    }

    /// 关闭发送（撤回同意、切换环境；FU-IOS-0711）：在登记任务的同一把锁里先执行 `invalidate`（ApiClient 推进作废世代、竖网络屏障，
    /// 取网络锁——锁顺序「传输锁 → 网络锁」，与 `send` 的最终准入相同），再取消此刻登记的全部任务。之后任何请求的最终准入都看到新世代。
    func closeAll(_ invalidate: () -> Void) {
        probe?.closeRequested()
        let running: [URLSessionTask] = lock.withLock {
            invalidate()
            probe?.invalidated()
            return Array(tasks.values)
        }
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

/// 传输层测试观察点（FU-IOS-0711 R1-01）：确定性构造「最终准入通过 → 切换推进作废世代 → 启动」的交错。
/// 生产不设置（`HttpTransport.probe` 为 nil，各调用点是一次可选链空操作）；协议是 internal，不进公开接口。
/// 调用位置：`admitted` / `starting` 在 `send` 的准入与 `task.resume` 之间（当前实现在传输锁里）；`closeRequested` 在 `closeAll`
/// 取传输锁之前；`invalidated` 在 `closeAll` 的传输锁里、作废之后。`admitted` 可以阻塞（模拟准入之后被抢占）。
protocol HttpTransportProbe: AnyObject, Sendable {
    func admitted(_ live: Bool)
    func starting(_ live: Bool)
    func closeRequested()
    func invalidated()
}
