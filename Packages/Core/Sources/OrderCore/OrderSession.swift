import Combine
import CouliNetwork
import Foundation

/// 订单执行器用到的网络能力（生产为 ApiClient）：`isValid` 是请求归属（页面、查询轮次、会话世代；失效即作废、迟到响应丢弃），
/// `sendAllowed` 是独立的发送前闸门（共享 42901 禁用期），只在每次实际写出前核对、不进归属（APP-08 共性第 13、27 条）；
/// `expected` 是执行器固定身份里的网络归属（账号、会话世代、环境票据），网络层在首次归属绑定与实际发送前只比较，不一致零发送（iOS RC-01）。
public protocol OrderApi: AnyObject, Sendable {
    func send(
        _ call: ApiCall,
        isValid: @escaping @Sendable () -> Bool,
        sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult
}

extension ApiClient: OrderApi {}

/// 一次请求的归属（线程安全）：页面离开、新一轮查询、会话换代时同步置为无效。ApiClient 在任意线程读取。
final class OrderRequestOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }
}

/// 在途请求：归属 + 可取消的 Task（取消即取消传输）。
@MainActor
final class OrderInFlight {
    private var entries: [Int: (owner: OrderRequestOwner, cancel: () -> Void)] = [:]
    private var next = 0

    /// 发出一次调用；结果在主线程交给 `settle`（调用方先复核轮次与会话）。
    func send(
        _ api: OrderApi, _ call: ApiCall, gate: OrderRateGate, owner fixed: OrderOwner,
        settle: @escaping @MainActor (ApiResult) -> Void
    ) {
        next += 1
        let id = next
        let owner = OrderRequestOwner()
        let allowed = gate.sendAllowed
        // 执行器固定的网络归属（RC-01）：排队到 Task 执行前会话换代的，网络层比较不一致即零发送，不重新绑定当前会话
        let expected = fixed.request
        let task = Task { @MainActor [weak self] in
            let result = await api.send(call, isValid: { owner.isValid }, sendAllowed: allowed, expected: expected)
            self?.entries[id] = nil
            guard owner.isValid else { return }
            settle(result)
        }
        entries[id] = (owner, { task.cancel() })
    }

    /// 作废并取消全部在途请求。
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

/// 截止时刻（线程安全：发送前闸门在任意线程读）。
final class OrderDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var until: Int64 = 0

    var value: Int64 {
        get { lock.withLock { until } }
        set { lock.withLock { until = newValue } }
    }
}

/// 订单请求的 42901 禁用期（APP-08 共性第 2、13、27 条）：按会话共享一份——订单列表、翻页、详情、待跟单查询与关闭（含商品详情 / 搜索页的
/// 卡片位置）共用同一个截止时间。任一订单请求收到 42901 都按 Retry-After（缺省或非法 5 秒）延长它；每个请求把 `sendAllowed` 作为发送前闸门
/// 交给网络层（每次实际写出前核对：首发、读接口退避后的重试、重签与刷新后的重放），页面按 `blocked` 同步禁用刷新、翻页、筛选、搜索、关闭与
/// 【重试】。已写出的请求不因禁用期被取消，成功与错误响应（含 10405）照常处理。重进页面拿到的仍是同一份；会话换代时 `reset`（A09 同口径）。
@MainActor
public final class OrderRateGate: ObservableObject {
    @Published public private(set) var blocked = false
    private let deadline = OrderDeadline()
    private let clock: @Sendable () -> Int64
    private var timer: Task<Void, Never>?

    public init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 执行层的判定（按时钟现算）。
    public var active: Bool {
        clock() < deadline.value
    }

    /// 发送前闸门（任意线程可调）。
    public nonisolated var sendAllowed: @Sendable () -> Bool {
        let deadline = deadline
        let clock = clock
        return { clock() >= deadline.value }
    }

    /// 剩余毫秒（页面显示用；不在禁用期为 0）。
    public var remainingMillis: Int64 {
        max(0, deadline.value - clock())
    }

    /// 开始（或延长）禁用；不缩短已有的截止时刻。
    public func start(_ millis: Int64) {
        guard millis > 0 else { return }
        deadline.value = max(deadline.value, clock() + millis)
        blocked = true
        arm()
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

    /// 会话换代：旧会话的禁用期不带给新会话。
    public func reset() {
        timer?.cancel()
        timer = nil
        deadline.value = 0
        blocked = false
    }
}

/// 订单执行器的固定身份（APP-09 共性第 65 条，iOS RC-01）：列表 / 详情 / 待跟单执行器在**构造时一次性**取得（App 一次读取会话：账号、
/// 会话世代、网络作废世代、订单清理次数、是否登录），结果、票据、请求结算、缓存读写、恢复记录保存都只用这一份；之后对当前会话的读取
/// 只允许经 `OrderOwnerSource.isCurrent` 与它**比较**，不得再读当前会话来赋值或绑定。
public struct OrderOwner: Equatable, Sendable {
    /// 账号（nil = 没有会话或撤回清理进行中；不读不写缓存、不保存恢复记录）。
    public let account: String?
    /// App 侧会话 / 隐私 / 环境版本（账号 + 会话世代 + 网络作废世代 + 订单清理次数）。
    public let key: String
    /// 已登录（有会话；游客不出通知行）。
    public let member: Bool
    /// 网络归属（账号、会话世代、环境票据；与上面几项同一次读取）。订单请求原样交给网络层比较（iOS RC-01）；nil = 不比较。
    public let request: RequestOwnership?

    public init(account: String?, key: String, member: Bool, request: RequestOwnership? = nil) {
        self.account = account
        self.key = key
        self.member = member
        self.request = request
    }
}

/// 固定身份的来源（App 给）：`currentOwner` 只在执行器构造时（或会话换代通知里随清空一起重建时）调用一次；`isCurrent` 只做比较。
@MainActor
public protocol OrderOwnerSource: AnyObject {
    /// 此刻的身份（一次读取）。
    func currentOwner() -> OrderOwner
    /// 固定身份仍是当前会话（且撤回清理不在进行中）。
    func isCurrent(_ owner: OrderOwner) -> Bool
}

/// 订单页面的一条轻提示：`key` 为文案键；`error` 不为 nil 时正文按统一的错误消息生成（带 trace6，共性第 8 条）。`id` 每次递增。
public struct OrderToast: Equatable, Sendable {
    public let key: String
    public let error: OrderErrorView?
    public let id: Int

    public init(key: String, error: OrderErrorView?, id: Int) {
        self.key = key
        self.error = error
        self.id = id
    }

    public func message(_ texts: OrderTexts) -> String {
        error.map { OrderErrorAction.message(texts, $0) } ?? texts.text(key)
    }
}

/// 会话级的订单协调器（一个进程一份，App 持有）：
/// - 共享 42901 禁用期 `gate`（共性第 2、13、27 条）；
/// - 已关闭成功的待跟单尝试 `closed`（link_id + attempt_id）与在途关闭 `dismissing`：订单列表、商品详情、搜索页各显示位置共用，任一位置关闭成功后
///   各处立即隐藏，之后才到的旧快照不得复活它；关闭在途时各处同一尝试都显示忙碌（共性第 3、14、15 条，鸿蒙 H26）；
/// - 通知行「点过」`pushRowUsed`（设备级，本机偏好；任一位置点过，各处立即移除通知行，共性第 25 条）与系统通知状态缓存 `notification`；
/// - 会话换代 `sessionChanged`：禁用期、关闭记录、在途关闭全部重置，`sessionEpoch` 加一（各执行器据此作废）。
@MainActor
public final class OrderSessionHub: ObservableObject {
    public static let pushRowUsedKey = "orders.push_row_used"

    public let gate: OrderRateGate
    @Published public private(set) var closed: Set<String> = []
    @Published public private(set) var dismissing: Set<String> = []
    @Published public private(set) var pushRowUsed: Bool
    /// 系统通知状态（PendingTrackRaw：not_determined / granted / denied / system_default），App 回前台、申请结束后刷新。
    @Published public var notification: String
    @Published public private(set) var sessionEpoch = 0
    private let defaults: UserDefaults

    public init(gate: OrderRateGate = OrderRateGate(), defaults: UserDefaults = .standard,
                notification: String = PendingTrackRaw.systemDefault) {
        self.gate = gate
        self.defaults = defaults
        self.notification = notification
        pushRowUsed = defaults.bool(forKey: Self.pushRowUsedKey)
    }

    public func markClosed(_ key: String) {
        closed.insert(key)
    }

    func beginDismiss(_ key: String) -> Bool {
        guard !dismissing.contains(key) else { return false }
        dismissing.insert(key)
        return true
    }

    func endDismiss(_ key: String) {
        dismissing.remove(key)
    }

    /// 点了【开启通知】：先写本机记录（之后不再出这一行，无论结果；卸载即清），各显示位置随之移除通知行。
    public func markPushRowUsed() {
        defaults.set(true, forKey: Self.pushRowUsedKey)
        pushRowUsed = true
    }

    /// 会话换代（登录、退出、换账号、会话失效）。
    public func sessionChanged() {
        gate.reset()
        closed = []
        dismissing = []
        sessionEpoch += 1
    }
}
