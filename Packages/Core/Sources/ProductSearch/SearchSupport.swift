import CouliNetwork
import Foundation

/// 搜索与详情执行器用到的网络能力（生产为 ApiClient；`send(_:isValid:)` 让 ApiClient 在每次等待结束、重试与实际发出前
/// 都核对归属，调用方 Task 被取消时同时取消传输）。
public protocol SearchApi: AnyObject, Sendable {
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult
    /// 带流程固定的请求归属发送（APP-08 iOS r3f NEW-03）：由购买 / 授权流程派生、经本模块发出的请求（购买结果触发的商品补齐、30144
    /// 重新加载）把那次购买尝试固定的归属交网络层，首次绑定前、组请求后与写出前只比较，不一致零发送。`expected` 为 nil 时同
    /// `send(_:isValid:)`。
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool, expected: RequestOwnership?) async -> ApiResult
}

extension ApiClient: SearchApi {
    public func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, expected: RequestOwnership?
    ) async -> ApiResult {
        guard let expected else {
            return await send(call, isValid: isValid)
        }
        return await send(call, isValid: isValid, sendAllowed: { true }, expected: expected)
    }
}

/// 搜索页用到的配置能力（生产为 App 的 AppConfig → ConfigStore；测试用假实现）。
@MainActor
public protocol SearchConfigSource: AnyObject {
    /// ConfigStore.searchStatusLayers（SearchTabs.resolve 的输入）。
    func searchStatusLayers() -> [String: Any]
    /// 最近一次被服务端确认的那份配置里的 search_status 原样对象（ConfigStore.confirmedSearchStatus）。
    var confirmedSearchStatus: [String: Any]? { get }
    /// 已发出的配置拉取的最大编号（在 requestFresh 之前取，作为「之后的配置」的分界）。
    var issuedFetchId: UInt64 { get }
    /// 最近一次被服务端确认（200 或有效的 304）的拉取编号；大于分界即分界之后发出并确认的配置。
    var appliedFetchId: UInt64 { get }
    /// 刷新配置（50304 search_disabled，error-codes「刷新配置」）：保证之后有一次在此刻之后才发出的拉取。
    func requestFresh()
    /// 订阅配置变化（含 304 确认）；返回的令牌释放或 cancel 时注销。
    func observeSearchConfig(_ handler: @escaping @MainActor () -> Void) -> SearchObservation
}

/// 订阅令牌。
@MainActor
public final class SearchObservation {
    private var cancelAction: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// 页面文案来源（App 实现：契约字典 DefaultTexts → 草稿表 SearchDraftTexts）。本模块与 Search / Product 功能模块不出现中文。
public protocol SearchTexts {
    /// 缺键返回空串。
    func text(_ key: String) -> String
    /// 带 {变量}：替换后仍有未给值的占位时用契约 fallback（没有则去掉占位）。
    func format(_ key: String, _ vars: [String: String]) -> String
}

/// 一次请求的归属（线程安全）：序号失效、页面离开时同步置为无效。ApiClient 在任意线程读取。
final class RequestOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }
}

/// 在途请求：归属 + 可取消的 Task（取消即取消传输，ApiClient `cancelWithTask`）。
@MainActor
final class InFlightRequests {
    private var entries: [Int64: (owner: RequestOwner, cancel: () -> Void)] = [:]

    /// 发出一次调用；Task 在主线程结算（结算前先由调用方复核序号）。
    /// `expected`：流程固定的请求归属（购买派生的补齐，r3f NEW-03）；nil = 页面自己的请求（不比较）。
    func send(
        _ api: SearchApi, _ call: ApiCall, seq: Int64, expected: RequestOwnership? = nil,
        settle: @escaping @MainActor (ApiResult) -> Void
    ) {
        let owner = RequestOwner()
        let task = Task { @MainActor [weak self] in
            let result = expected == nil
                ? await api.send(call) { owner.isValid }
                : await api.send(call, isValid: { owner.isValid }, expected: expected)
            self?.entries[seq] = nil
            settle(result)
        }
        entries[seq] = (owner, { task.cancel() })
    }

    /// 作废并取消全部在途请求（新请求开始、离开页面、平台失效时）。
    func cancelAll() {
        let all = entries.values
        entries = [:]
        for entry in all {
            entry.owner.invalidate()
            entry.cancel()
        }
    }

    var count: Int {
        entries.count
    }
}

/// 限时禁用（42901，error-codes：按 Retry-After 禁用按钮，缺省 5 秒）：记下截止时刻，到期通知一次；判定一律按时钟。
@MainActor
final class RetryBlock {
    private var until: Int64 = 0
    private var timer: Task<Void, Never>?
    private let clock: () -> Int64

    init(clock: @escaping () -> Int64) {
        self.clock = clock
    }

    var active: Bool {
        clock() < until
    }

    func start(_ millis: Int64, onExpire: @escaping @MainActor () -> Void) {
        until = max(until, clock() + millis)
        arm(onExpire)
    }

    private func arm(_ onExpire: @escaping @MainActor () -> Void) {
        timer?.cancel()
        let wait = max(0, until - clock())
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            if active {
                arm(onExpire)
                return
            }
            onExpire()
        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// 结果换算的公共工具。
public enum SearchResults {
    /// 42901 的禁用时长：取网络层 ErrorEffect.disableMillis（缺省 5 秒）；其余为 0（不禁用）。
    public static func disableMillis(_ result: ApiResult) -> Int64 {
        guard case let .failure(code, _, _, _, effect, _) = result else { return 0 }
        if effect.kind == .disableButton, code == 42901 {
            return effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
        }
        return code == 42901 ? ErrorActionMapper.defaultRetryAfterMillis : 0
    }

    /// 统一外壳（SearchResultState.map 的输入）；没有外壳（断网、超时、本地拒绝）为 nil。
    public static func envelope(_ result: ApiResult) -> [String: Any]? {
        switch result {
        case let .success(data, traceId, _):
            ["code": 0, "msg": "", "data": JSON.parse(data) ?? [:], "trace_id": traceId ?? ""]
        case let .failure(code, msg, data, traceId, _, _):
            ["code": code, "msg": msg, "data": JSON.parse(data) ?? [:], "trace_id": traceId ?? ""]
        default:
            nil
        }
    }

    /// 没有外壳的失败：错误态，文案键取网络层给的（没有为 nil，页面用通用失败兜底）。
    static func transportError(_ result: ApiResult) -> SearchResultView {
        var key: String?
        if case let .sessionCleared(effect) = result {
            key = effect.textKey
        }
        return SearchResultView(stateRaw: SearchStateRaw.error, textKey: key, code: -1)
    }

    /// trace_id 后 6 位（03 §4.2 通用错误态）；没有 trace_id 为空串（文案按无编号的 fallback）。
    public static func trace6(_ traceId: String) -> String {
        String(traceId.suffix(6))
    }
}

/// 搜索 / 详情错误文案（03 §4.2、BR-TEXT-14）：error.<code>[.<reason>]；{platform_name} 用平台显示名。没有键或键的文字为空
/// 时用通用失败键 error.50001。追踪编号统一生成（共性 6、9、12）：有 trace_id 就显示末六位——文案键里有 {trace6} 占位的
/// 填进去，没有的（50304、search_disabled 等）在正文后补「（xxxxxx）」（草稿键 error.trace_suffix），已含编号不重复；
/// 只有确实没有 trace_id 时才用不带编号的文案。
public enum SearchErrorText {
    public static let genericKey = "error.50001"
    /// 追踪编号后缀（「（{trace6}）」；契约无键，TODO(N-27) 草稿表）。
    public static let traceSuffixKey = "error.trace_suffix"

    public static func platformKey(_ platform: String) -> String {
        "platform." + platform
    }

    public static func text(_ error: SearchResultView?, texts: SearchTexts, currentPlatform: String?) -> String {
        guard let error else { return "" }
        let platform = error.platform ?? currentPlatform
        let trace6 = SearchResults.trace6(error.traceId)
        let vars = [
            "platform_name": platform.map { texts.text(platformKey($0)) } ?? "",
            "trace6": trace6,
        ]
        var text = texts.format(error.textKey ?? genericKey, vars)
        if text.isEmpty {
            text = texts.format(genericKey, vars)
        }
        guard !trace6.isEmpty, !text.contains(trace6) else { return text }
        return text + texts.format(traceSuffixKey, ["trace6": trace6])
    }
}
