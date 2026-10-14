import Foundation

/// 钱包集成测试的本地假服务（URLProtocol）：记录每个请求的方法、路径、查询、请求体与请求头；回答由测试脚本决定，可挂起后放行、可按传输失败
/// 结束（超时、断连、响应丢失）。不连任何地址。姓名、卡号等测试值都是明显的测试值，失败信息不打印请求体。
final class WalletStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        /// 统一外壳：code、data 的 JSON 文本、响应头。
        case envelope(code: Int, data: String, headers: [String: String])
        /// 传输失败（断连）：没有统一外壳。
        case disconnect
        /// 挂起，等 `release` 给出真正的回答。
        case hold
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let query: String
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
    private nonisolated(unsafe) static var held: [Int: WalletStubProtocol] = [:]
    private nonisolated(unsafe) static var next = 0
    private var stopped = false
    private let stoppedLock = NSLock()

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WalletStubProtocol.self]
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

    /// 放行一个挂起的请求。
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
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let entry: Recorded = Self.lock.withLock {
            Self.next += 1
            return Recorded(
                method: request.httpMethod ?? "GET", path: components?.path ?? url.path,
                query: components?.percentEncodedQuery ?? "", body: Self.body(request),
                headers: request.allHTTPHeaderFields ?? [:], id: Self.next
            )
        }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry) ?? .envelope(code: 0, data: "{}", headers: [:])
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
        case .disconnect:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case let .envelope(code, data, headers):
            let text = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"stub-trace-0123456789ab\"}"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
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

/// 样例数据（sample-data §12；与 Android / 鸿蒙的假服务同一份）。
enum WalletSamples {
    static let summary = """
    {"available_fen":1000,"withdrawable_fen":1000,"negative_fen":0,"frozen_fen":200,"estimated_total_fen":1019,\
    "estimated_fen":269,"pending_credit_fen":750,"pending_credit_paused_fen":450,"next_credit_period":"2026-11",\
    "credit_overdue":false,"withdrawn_fen":0,"risk_paused_reason":null,"withdraw_enabled":true}
    """

    static func rules(can: Bool = true, block: Int? = nil, reason: String? = nil, net: Int64? = nil) -> String {
        let blockText = block.map(String.init) ?? "null"
        let reasonText = reason.map { "\"\($0)\"" } ?? "null"
        let est = net.map { "\"est_fee_fen\":0,\"est_tax_fen\":0,\"est_net_fen\":\($0)" }
            ?? "\"est_fee_fen\":null,\"est_tax_fen\":null,\"est_net_fen\":null"
        return "{\"can_withdraw\":\(can),\"block_code\":\(blockText),\"block_reason\":\(reasonText),"
            + "\"max_withdrawable_fen\":\(can ? 1200 : 0),\"withdrawable_fen\":1234,\"daily_remaining\":1,"
            + "\"monthly_remaining\":10,\(est),\"quick_amounts_fen\":\(can ? "[500,1000]" : "[]")}"
    }

    static let alipay = """
    {"payout_method":"alipay","masked_account":"138****5678","masked_payee_name":"**三","change_remaining_this_month":2}
    """

    static func withdrawal(_ id: String, status: String = "PENDING_REVIEW", channel: String? = nil) -> String {
        let order = channel.map { ",\"channel_order_id\":\"\($0)\"" } ?? ",\"channel_order_id\":null"
        return "{\"withdrawal_id\":\"\(id)\",\"status\":\"\(status)\",\"review_mode\":\"manual\",\"amount_fen\":1000,"
            + "\"fee_fen\":0,\"tax_fen\":0,\"net_fen\":1000,\"payout_channel\":\"alipay\","
            + "\"payout_channel_name\":\"支付宝\","
            + "\"masked_account\":\"138****5678\",\"reason_code\":null,\"fail_action\":null,"
            + "\"created_at\":\"2026-10-12T10:00:00+08:00\"\(order)}"
    }

    static let me = "{\"user_id\":\"user-a\",\"realname_status\":\"verified\",\"phone_bound\":true}"
}
