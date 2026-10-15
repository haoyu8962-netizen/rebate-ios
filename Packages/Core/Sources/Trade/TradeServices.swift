import CouliNetwork
import Foundation

/// 契约 operationId（ApiOperations）。
public enum TradeOperations {
    public static let openLink = "openLink"
    public static let getUnionAuthUrl = "getUnionAuthUrl"
    public static let bindUnion = "bindUnion"
    public static let listUnionBindings = "listUnionBindings"
    public static let getTips = "getTips"
    public static let markTipRead = "markTipRead"
    public static let getProduct = "getProduct"
}

/// 购买流程用到的网络能力（生产为 ApiClient；`send(_:isValid:)` 让 ApiClient 在每次等待结束、重试与实际发出前都核对归属，
/// 调用方 Task 被取消时同时取消传输）。
public protocol TradeApi: AnyObject, Sendable {
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult
    /// 带调用方固定的请求归属发送（iOS RC-06：JumpTip 的 getTips / markTipRead）：`expected` 非 nil 时网络层在首次归属绑定前、组请求后与
    /// 实际写出前只比较，账号 / 会话世代 / 作废世代不一致即本地结束、零发送；nil 与 `send(_:isValid:)` 相同。
    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool, expected: RequestOwnership?) async -> ApiResult
}

extension ApiClient: TradeApi {
    public func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, expected: RequestOwnership?
    ) async -> ApiResult {
        guard expected != nil else {
            return await send(call, isValid: isValid)
        }
        return await send(call, isValid: isValid, sendAllowed: { true }, expected: expected)
    }
}

/// 一次请求的归属（线程安全）：所属的点击 / 授权世代失效、页面离开时同步置为无效（ApiClient 在任意线程读取）。
public final class TradeOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}

    public var isValid: Bool {
        lock.withLock { valid }
    }

    public func invalidate() {
        lock.withLock { valid = false }
    }
}

/// 在途请求：归属 + 可取消的 Task。先作废归属、再取消传输（取消到达传输层时归属已失效，不会被当成断连重试，共性第 20 条）。
@MainActor
public final class TradeCalls {
    private struct Entry {
        let owner: TradeOwner
        let group: String
        let cancel: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private let api: TradeApi

    public init(api: TradeApi) {
        self.api = api
    }

    /// 发出一次调用，`group` 用于按类作废（open 请求、授权、须知等）。返回结果在主线程交给调用方，调用方须再复核归属。
    public func send(_ call: ApiCall, group: String, expected: RequestOwnership? = nil) async -> ApiResult {
        let owner = TradeOwner()
        let id = UUID()
        let api = api
        let task = Task {
            if let expected {
                return await api.send(call, isValid: { owner.isValid }, expected: expected)
            }
            return await api.send(call) { owner.isValid }
        }
        entries[id] = Entry(owner: owner, group: group, cancel: { task.cancel() })
        let result = await task.value
        entries[id] = nil
        return result
    }

    /// 作废并取消某一类（nil = 全部）在途请求。
    public func cancel(group: String? = nil) {
        let matched = entries.filter { group == nil || $0.value.group == group }
        for (id, entry) in matched {
            entries[id] = nil
            entry.owner.invalidate()
            entry.cancel()
        }
    }

    public func count(group: String? = nil) -> Int {
        entries.values.filter { group == nil || $0.group == group }.count
    }
}

/// 购买的 pending_action（BR-ID-10）：App 用 Router 的同一份本地记录（只存 1 条、10 分钟、完成一步重新计时、退出登录清除）实现。
/// 动作名 `action`；params 不含令牌、验证码（只有 kind、link_id、平台、商品键与本次的幂等键）。
@MainActor
public protocol PurchasePending: AnyObject {
    /// 登记（新的覆盖旧的）；失败返回 false。
    @discardableResult
    func register(_ params: TradeObject) -> Bool
    /// 有效的购买待办（未过期、动作名对）；没有为 nil。不删除。
    func peek() -> TradeObject?
    /// 完成了一个前置步骤（登录、授权）：重新计时。
    func stepDone()
    /// 删除（执行前、放弃、页面出栈）。
    func clear()
    /// 待办此刻处于暂缓（APP-05b：第三方新号登录后、绑手机引导结束前）：自动恢复只保留记录，等释放通知再恢复（R1-01）。
    var held: Bool { get }
}

public extension PurchasePending {
    var held: Bool {
        false
    }
}

public enum PurchasePendingKeys {
    public static let action = "open_link"
    public static let kindLogin = "login"
    public static let kindAuth = "auth"
    public static let kindConsent = "consent"
    /// 登记待办的发起页执行器标识（共性第 44 条）。
    public static let owner = "owner"
    /// 登记待办的购买尝试（点击编号）。
    public static let attempt = "attempt"
}

/// 内存实现（测试、没有持久化的场合）。
@MainActor
public final class MemoryPurchasePending: PurchasePending {
    /// 暂缓（测试与没有 Router 的组合用）。
    public var held = false
    private var params: TradeObject?
    private var startedAt: Int64 = 0
    private let clock: () -> Int64
    public static let ttlMillis: Int64 = 600_000

    public init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    @discardableResult
    public func register(_ params: TradeObject) -> Bool {
        self.params = params
        startedAt = clock()
        return true
    }

    public func peek() -> TradeObject? {
        guard let params else { return nil }
        let age = clock() - startedAt
        guard age >= 0, age <= Self.ttlMillis else {
            self.params = nil
            return nil
        }
        return params
    }

    public func stepDone() {
        if peek() != nil {
            startedAt = clock()
        }
    }

    public func clear() {
        params = nil
    }
}

/// AuthSheet 自动弹出计数（BR-ID-18）：每次因 30101 / 30102 / 30111 自动弹出记 1 次，按平台存在内存；同一会话每个平台最多 2 次，
/// 第 3 次起点击购买直接给「未授权将无法获得返利」二选一。进程冷启动或在后台停留 ≥ 1800 秒后回前台时清零。App 里一个进程一份。
/// TODO(N-28)：登录 / 退出 / 换账号是否清零未规定（rule-gaps I 段），不清零。
@MainActor
public final class AuthSheetCounter {
    public static let maxAutoPops = 2
    public static let resetAfterMillis: Int64 = 1_800_000
    private var counts: [String: Int] = [:]
    private var backgroundAt: Int64?
    private let clock: () -> Int64

    public init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 这次还能自动弹出：能就记 1 次并返回 true。
    public func tryAutoPop(_ platform: String) -> Bool {
        let count = counts[platform] ?? 0
        guard count < Self.maxAutoPops else { return false }
        counts[platform] = count + 1
        return true
    }

    public func count(_ platform: String) -> Int {
        counts[platform] ?? 0
    }

    public func onBackground() {
        backgroundAt = clock()
    }

    public func onForeground() {
        guard let since = backgroundAt else { return }
        backgroundAt = nil
        if clock() - since >= Self.resetAfterMillis {
            counts = [:]
        }
    }
}

/// 授权凭证（bindings 请求体的一种，BR-ID-17 细则「授权方式」）。只交给 bindings，不保存、不进日志。
public enum AuthCredential: Sendable {
    case webCode(String)
    case sdkToken(accessToken: String, expiresIn: Int64)
}

/// 一次授权步骤（拉起授权页 / SDK）的结果。
public enum AuthStepResult: Sendable {
    case credential(AuthCredential)
    case cancelled
    case failed
}

/// 淘宝 web_code 授权的本端能力（App 给）：用系统浏览器打开 auth_url，等本 App 自己的回跳 scheme 带回授权码。
/// 回跳 scheme 在 apps.json inbound 登记前（为空，TODO(N-28)）生产实现 `available` = false。
@MainActor
public protocol WebCodeAuthorizer: AnyObject {
    var available: Bool { get }
    func authorize(authUrl: String, state: String) async -> AuthStepResult
}

/// 生产：回跳 scheme 未登记，web_code 不可执行（TODO(N-28)：apps.json inbound 补上后接系统浏览器 + 回跳）。
@MainActor
public final class UnavailableWebCodeAuthorizer: WebCodeAuthorizer {
    public init() {}

    public var available: Bool {
        false
    }

    public func authorize(authUrl _: String, state _: String) async -> AuthStepResult {
        .failed
    }
}

/// bindings 请求体（BR-ID-17：只有 state、auth_method 与凭证字段）。
func bindBody(state: String, credential: AuthCredential) -> String {
    switch credential {
    case let .webCode(code):
        TJSON.encode(["state": state, "auth_method": AuthMethodPicker.webCode, "code": code])
    case let .sdkToken(token, expiresIn):
        TJSON.encode([
            "state": state, "auth_method": AuthMethodPicker.sdkToken, "access_token": token, "expires_in": expiresIn,
        ])
    }
}

/// 点击结果确认的平台购买状态（50301 maintenance / not_launched；03 §7.4「点击时以响应为准」，APP-06b 共性第 5、6 条）：按平台记下，
/// 进程里一份（AppTrade），列表、详情的卡片映射与点击前核对都先读它。记下时取配置拉取的分界（`issuedMark`）；分界之后发出、已生效的
/// 配置（`appliedMark` 超过分界）到达后以新配置为准，这条记录作废。TODO(N-28)：有效期与是否跨页面未规定（A17 同口径）。
@MainActor
public final class PlatformStatusOverrides {
    private let issuedMark: @MainActor () -> UInt64
    private let appliedMark: @MainActor () -> UInt64
    private var marks: [String: (status: String, mark: UInt64)] = [:]
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    public init(issuedMark: @escaping @MainActor () -> UInt64, appliedMark: @escaping @MainActor () -> UInt64) {
        self.issuedMark = issuedMark
        self.appliedMark = appliedMark
    }

    public func mark(_ platform: String, status: String) {
        marks[platform] = (status, issuedMark())
        listeners.values.forEach { $0() }
    }

    /// 仍有效的记录；没有或已被新配置覆盖为 nil。
    public func status(_ platform: String) -> String? {
        guard let entry = marks[platform] else { return nil }
        if appliedMark() > entry.mark {
            marks[platform] = nil
            return nil
        }
        return entry.status
    }

    /// 记录变化时通知（主线程）；返回取消订阅。
    public func subscribe(_ listener: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            MainActor.assumeIsolated { self?.listeners[id] = nil }
        }
    }
}

/// 结果换算。
public enum TradeResults {
    /// 42901 的禁用时长：网络层 ErrorEffect.disableMillis（缺省 5 秒）；其余为 0（不禁用）。
    public static func disableMillis(_ result: ApiResult) -> Int64 {
        guard case let .failure(code, _, _, _, effect, _) = result, code == 42901 else { return 0 }
        return effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
    }

    /// trace_id 后 6 位（03 §4.2）；没有为 nil。
    public static func trace6(_ traceId: String?) -> String? {
        guard let traceId, !traceId.isEmpty else { return nil }
        return String(traceId.suffix(6))
    }
}

/// 限时禁用（42901 Retry-After，缺省 5 秒）：记下截止时刻，到期通知一次；判定一律按时钟。
@MainActor
public final class TradeRetryGate {
    private var until: Int64 = 0
    private var timer: Task<Void, Never>?
    private let clock: () -> Int64

    public init(clock: @escaping () -> Int64) {
        self.clock = clock
    }

    public var active: Bool {
        clock() < until
    }

    public func start(_ millis: Int64, onExpire: @escaping @MainActor () -> Void) {
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

    public func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
