import Foundation

/// 测试脚本：按「方法 路径」给回答；没登记的用样例缺省。可按次序给一串回答（用完后用最后一个）。线程安全（URLProtocol 在任意线程调用）。
final class WalletScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [WalletStubProtocol.Reply]] = [:]

    /// 登记 `key`（如 "POST /v1/withdrawals"）的回答序列。
    func on(_ key: String, _ replies: WalletStubProtocol.Reply...) {
        lock.withLock { queues[key] = replies }
    }

    func ok(_ key: String, _ data: String) {
        on(key, .envelope(code: 0, data: data, headers: [:]))
    }

    func fail(_ key: String, _ code: Int, data: String = "null", headers: [String: String] = [:]) {
        on(key, .envelope(code: code, data: data, headers: headers))
    }

    func reply(_ request: WalletStubProtocol.Recorded) -> WalletStubProtocol.Reply {
        let key = "\(request.method) \(request.path)"
        let scripted: WalletStubProtocol.Reply? = lock.withLock {
            guard var queue = queues[key], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            queues[key] = queue.isEmpty ? [first] : queue
            return first
        }
        return scripted ?? Self.fallback(request)
    }

    func install() {
        WalletStubProtocol.install { [self] request in reply(request) }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func fallback(_ request: WalletStubProtocol.Recorded) -> WalletStubProtocol.Reply {
        let ok: (String) -> WalletStubProtocol.Reply = { .envelope(code: 0, data: $0, headers: [:]) }
        switch (request.method, request.path) {
        case ("GET", "/v1/wallet/summary"): return ok(WalletSamples.summary)
        case ("GET", "/v1/withdrawals/rules"):
            let amount = request.query.components(separatedBy: "amount_fen=").dropFirst().first.flatMap { Int64($0) }
            return ok(WalletSamples.rules(net: amount))
        case ("GET", "/v1/me/payout-account"): return ok(WalletSamples.alipay)
        case ("GET", "/v1/me"): return ok(WalletSamples.me)
        case ("POST", "/v1/auth/sms-codes"): return ok("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        case ("POST", "/v1/auth/step-up"):
            return ok("{\"step_up_token\":\"fixture-step-up\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}")
        case ("POST", "/v1/withdrawals"): return ok(WalletSamples.withdrawal("W-new"))
        case ("GET", "/v1/withdrawals"):
            return ok("{\"items\":[\(WalletSamples.withdrawal("W1"))],\"next_cursor\":null}")
        case ("PUT", "/v1/me/payout-account"): return ok(WalletSamples.alipay)
        case ("POST", "/v1/idempotency-keys/abandon"): return ok("{\"outcome\":\"abandoned\",\"original\":null}")
        default:
            if request.path.hasPrefix("/v1/withdrawals/") {
                let id = String(request.path.dropFirst("/v1/withdrawals/".count))
                return ok(WalletSamples.withdrawal(id, status: "PAID_API", channel: "fixture-channel-001"))
            }
            return ok("{}")
        }
    }
}
