import Combine
import Foundation

/// 共用的 42901 禁用期（APP-09 brief §0「Retry-After」：iOS 原来只有 TradeResults / SearchResults / OrderRateGate 的私有版本，钱包类页面
/// 改用这一份）：一个截止时刻，收到 42901 按 Retry-After（缺省或非法 5 秒，`ErrorActionMapper.retryAfterMillis`）延长，不缩短。
/// - 页面按 `blocked` 同步置灰入口；
/// - 执行层把 `probe()` 交给网络层作发送前闸门（`ApiClient.send(_:isValid:sendAllowed:expected:)`，每次实际写出前核对，含自动重试与重放；
///   APP-08 共性第 13、27、32 条）。闸门不进请求归属：已写出的请求照常收结果。
/// - 被闸门拦下时记下明确原因（`SendProbe.rejected`，APP-09 共性第 62 条）：回调按它结算，不用回调时刻的禁用期反推。
/// 截止时刻线程安全（发送前闸门在任意线程读）；其余只在主线程用。已有调用方（订单、搜索、购买）不强制改。
@MainActor
public final class RetryAfterGate: ObservableObject {
    @Published public private(set) var blocked = false
    private let deadline = GateDeadline()
    private let clock: @Sendable () -> Int64
    private var timer: Task<Void, Never>?

    public init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 执行层的判定（按时钟现算，不看 `blocked` 的发布时机）。
    public var active: Bool {
        clock() < deadline.value
    }

    /// 剩余毫秒（不在禁用期为 0）。
    public var remainingMillis: Int64 {
        max(0, deadline.value - clock())
    }

    /// 发送前闸门（任意线程可调）：禁用期外放行。
    public nonisolated var sendAllowed: @Sendable () -> Bool {
        let deadline = deadline
        let clock = clock
        return { clock() >= deadline.value }
    }

    /// 一次请求的发送前闸门（APP-09 共性第 62 条）：`extra` 是调用方另外的发送条件（不算限流，例：发码的同一截止时间）。
    public nonisolated func probe(extra: (@Sendable () -> Bool)? = nil) -> SendProbe {
        SendProbe(allowedByGate: sendAllowed, extra: extra)
    }

    /// 开始（或延长）禁用；0 或负数不动。
    public func start(_ millis: Int64) {
        guard millis > 0 else { return }
        deadline.value = max(deadline.value, clock() + millis)
        blocked = true
        arm()
    }

    /// 会话换代：旧会话的禁用期不带给新会话。
    public func reset() {
        timer?.cancel()
        timer = nil
        deadline.value = 0
        blocked = false
    }

    private func arm() {
        timer?.cancel()
        let wait = max(1, deadline.value - clock())
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            if active {
                arm()
            } else {
                blocked = false
            }
        }
    }
}

/// 截止时刻（线程安全）。
final class GateDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var until: Int64 = 0

    var value: Int64 {
        get { lock.withLock { until } }
        set { lock.withLock { until = newValue } }
    }
}

/// 一次请求的发送前闸门（APP-09 共性第 62 条，Android RC-04 同口径）：网络层每次实际写出前调 `allowed`；禁用期内返回 false 并记下
/// 「本请求被发送前限流拒绝」。回调按 `gated(_:)` 结算（结束加载、显示 42901），不看回调时刻的禁用期——拒绝之后它可能已到期。
public final class SendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var wasRejected = false
    private let allowedByGate: @Sendable () -> Bool
    private let extra: (@Sendable () -> Bool)?

    init(allowedByGate: @escaping @Sendable () -> Bool, extra: (@Sendable () -> Bool)?) {
        self.allowedByGate = allowedByGate
        self.extra = extra
    }

    /// 交给网络层的发送前闸门。
    public var allowed: @Sendable () -> Bool {
        { [self] in
            guard allowedByGate() else {
                lock.withLock { wasRejected = true }
                return false
            }
            return extra?() ?? true
        }
    }

    /// 本请求被禁用期拦下过。
    public var rejected: Bool {
        lock.withLock { wasRejected }
    }

    /// 这次结果是本请求被发送前限流拦下（本地拒绝 send_blocked，且拒绝原因是禁用期）。
    public func gated(_ result: ApiResult) -> Bool {
        guard rejected, case let .localReject(reason) = result else { return false }
        return reason == LocalRejectReason.sendBlocked
    }
}

/// 统一错误消息里的 trace6（03 §4.2；APP-06a 第 6、12 条，APP-07 第 9 条，APP-08 第 8、16 条）：5xxxx 文案带 trace_id 末 6 位，由这里独立
/// 追加，不依赖文案里有 {trace6} 占位符（有占位就填进去，没有的补「（xxxxxx）」，已含编号不重复）；没有 trace_id 时不追加。
/// 钱包类页面用这一份，不再复制 TradeResults / SearchResults 的私有版本。
public enum ErrorTrace {
    /// 追加的后缀模板（契约没有这个键；与订单、搜索的草稿同文，TODO(N-27)）。
    public static let suffixTemplate = "（{trace6}）"

    /// trace_id 末 6 位；没有为空串。
    public static func trace6(_ traceId: String?) -> String {
        guard let traceId, !traceId.isEmpty else { return "" }
        return String(traceId.suffix(6))
    }

    /// 文案 + trace6：`format(key, vars)` 取文案并填变量；`append` 为 false 时只填占位、不另追加（非 5xxxx）。
    public static func message(
        key: String, traceId: String?, append: Bool, fallbackKey: String = "error.50001",
        format: (String, [String: String]) -> String
    ) -> String {
        let trace = trace6(traceId)
        let vars = trace.isEmpty ? [:] : ["trace6": trace]
        var body = format(key, vars)
        if body.isEmpty {
            body = format(fallbackKey, vars)
        }
        guard append, !trace.isEmpty, !body.contains(trace) else { return body }
        return body + suffixTemplate.replacingOccurrences(of: "{trace6}", with: trace)
    }
}
