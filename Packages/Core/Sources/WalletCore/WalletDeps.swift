import ClientCore
import CouliNetwork
import Foundation

/// 钱包类页面要的网络能力（生产为 ApiClient）：普通调用带请求归属（`isValid`）、独立的发送前闸门（`sendAllowed`，共享 42901 禁用期）与
/// 执行器固定的网络归属（`expected`，网络层只比较、不一致零发送）；未决键的恢复、确认与作废经 ApiClient 的已有入口（BR-ID-10），不重写管线。
public protocol WalletApi: AnyObject, Sendable {
    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult
    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult
    func abandonPending(operationId: String, target: PendingTarget) async -> ApiResult
    func pendingStatus(operationId: String) async -> PendingLookup
    func restorePending() async
}

extension ApiClient: WalletApi {}

/// 表单与页面执行器的固定身份（APP-09 共性第 52、59、65 条；iOS 照 APP-08 OrderOwner）：在执行器**构造时一次性**取得（App 一次读取：账号、
/// 会话世代、网络作废世代、钱包清理次数），恢复的金额、输入、渲染值、请求都只用这一份；之后对当前会话的读取只允许经 `WalletEnv.isCurrent`
/// 与它**比较**，不得再读当前会话来赋值或绑定。`request` 原样交给网络层比较（`ApiClient.send(…expected:)`、`PendingTarget`）。
public struct WalletOwner: Equatable, Sendable {
    /// 账号（nil = 没有会话或撤回清理进行中：不发请求、不读写缓存）。
    public let account: String?
    /// App 侧会话 / 隐私 / 环境版本（账号 + 会话世代 + 网络作废世代 + 清理次数）。
    public let key: String
    /// 网络归属（与上面几项同一次读取）。
    public let request: RequestOwnership?
    /// 持久化登录世代（FU-IOS-0712 R1-01；与账号同一次读取）：摘要与金额草稿按「账号 + 这一份世代」分区读写，写入时不再读当前世代。
    /// nil = 未知（不读不写）。
    public let loginEpoch: String?
    /// 构造时那一次读取身份是否已确认（FU-IOS-0712 整体重理，同 `OrderOwner.identityKnown`）。false = 身份暂时未知时构造：页面不加载、
    /// 不写，身份确认后由 App 换上已确认的身份。
    public let identityKnown: Bool

    public init(
        account: String?, key: String, request: RequestOwnership?, loginEpoch: String? = nil, identityKnown: Bool = true
    ) {
        self.account = account
        self.key = key
        self.request = request
        self.loginEpoch = loginEpoch
        self.identityKnown = identityKnown
    }

    /// 测试与占位：不属于任何会话（永远不是当前）。
    public static let none = WalletOwner(account: nil, key: "-", request: nil)
}

/// 实名提交（G01）：契约没有实名提交接口，手写的待定 operation submitRealname 只由 Debug 假服务实现；Release 为 nil，【提交认证】置灰并显示
/// 「实名认证暂未开放」，不发任何请求，也不调 /v1/consents。TODO(N-32) 契约补上后改为真实接口。
public protocol RealNameBackend: AnyObject, Sendable {
    /// 单独同意与实名提交（Debug 假服务里一起发生）；`owner` 是表单固定身份，实现方在实际处理前核对。
    func submit(name: String, idNo: String, idempotencyKey: String, owner: RequestOwnership?) async -> ApiResult
}

/// 劳务协议（G02）：取协议与签署走手写的待定 operation，只由 Debug 假服务实现；Release 为 nil（全文区「协议正文暂未提供」，【同意并签署】置灰）。
public protocol LaborBackend: AnyObject, Sendable {
    /// data：{version, text, text_sha256, need_sign}（形状照 04 §6.1；全文按「地址或文本」，假服务给文本）。
    func current(owner: RequestOwnership?) async -> ApiResult
    /// data：{}；sha256 取服务端返回的值原样回传。
    func sign(version: String, textSha256: String, owner: RequestOwnership?) async -> ApiResult
}

/// 钱包类页面要的环境（App 给；都在主线程调用）。`page` 是发起页的导航实例编号（RouteDestination.id，APP-09 共性第 50 条）：出栈、替换
/// 只作用于这一个实例，不按路由名找同名页面。
@MainActor
public protocol WalletEnv: AnyObject {
    /// 此刻的身份（一次读取）。只在执行器构造时、会话换代通知里随清空重建时调用。
    func currentOwner() -> WalletOwner
    /// 固定身份仍是当前会话（只比较；撤回清理进行中一律不是）。
    func isCurrent(_ owner: WalletOwner) -> Bool
    /// 固定身份与此刻身份的核对结论（一次读取；FU-IOS-0712 整体重理）：`isCurrent` 等价于 `.current`；`.unknown` = 身份暂时未知（或页面
    /// 构造时身份未确认、还没换上）——页面记待补做、身份确认后由 App 统一补做。
    func check(_ owner: WalletOwner) -> IdentityCheck
    /// 页面在身份暂时未知时被用户点了【重试】：请 App 立即核对一次身份。
    func recheckIdentity()
    /// /v1/config 的 texts 里的一项（生效配置）；没有为 nil。
    func configText(_ key: String) -> String?
    /// /v1/config.help_links。
    func helpLinks() -> [String: Any]?
    /// Config features.flags["earnings.dashboard.visible"]（G20）；没有为 nil。
    func earningsFlag() -> Bool?
    /// 本端版本与 Earnings 路由 since.ios（G20）。
    var appVersion: String { get }
    var earningsSince: String? { get }
    /// 经 Router 以 App 内来源打开（路由名都在 routes.json）。
    func open(_ route: String, params: [String: String], from page: UUID?)
    /// 用 `route` 替换发起页（提交成功进 WithdrawRecords {withdrawal_id}，G19）：只在它仍是栈顶时替换；返回是否替换了。
    func replace(page: UUID, route: String, params: [String: String]) -> Bool
    /// 出栈本页（实名、签署完成；G05）：只在它仍是栈顶时出栈；返回是否出栈了。
    func close(page: UUID) -> Bool
    /// 收款账号保存成功：下面是 Withdraw 就出栈回发起页；从别处进来的停在本页（brief §2.7）。返回是否已出栈。
    func payoutSaved(page: UUID) -> Bool
    /// 经 App 写剪贴板的唯一入口（APP-07 ClipboardWriter：先记自写 hash 并确认落盘，记不下就不写）；返回是否写入。
    func copy(_ text: String) -> Bool
    /// 【联系客服】/【联系客服申诉】：统一客服出口接入前经 Router 打开 Help（同 APP-08 G09）。
    func contactService(from route: String)
    /// 二次验证发码用的手机号（G31）：本机有当前账号、并且绑定了账号归属的号码才给；没有为 nil（不编造，不让用户另填；iOS I01）。
    func stepUpPhone(account: String) -> String?
    /// 钱包摘要需要刷新（提现成功、放弃得到 completed 成功，G19）：`owner` 是共享结算已核对的点击时身份，原样放进失效通知。
    func markWalletDirty(_ owner: WalletOwner)
    /// 实名成功：刷新 GET /v1/me 的 realname_status，守卫按已实名放行（G05）。
    func realnameChanged()
    /// 二次验证、单独同意等敏感浮层出现 / 关闭（剪贴板等迟到结果只丢弃，APP-07 第 4 条）。
    func sensitiveOverlay(_ showing: Bool)
    /// 本机时钟（禁用期、发码倒计时、token 过期）。
    func nowMillis() -> Int64
    /// 服务端校准后的时钟（缓存时间提示等显示用，BR-TEXT-11）。
    func displayNowMillis() -> Int64
}

/// 会话级共享的几份禁用期（App 建一份，会话换代时整体 `reset`）。共享范围（brief §0「Retry-After」）：读请求一份；提现提交 / 确认 / 放弃一份；
/// 收款账号保存 / 确认 / 放弃一份；发码一份；验证一份；实名、劳务协议各一份。
@MainActor
public final class WalletGates {
    public let read: RetryAfterGate
    public let withdraw: RetryAfterGate
    public let payout: RetryAfterGate
    public let sms: RetryAfterGate
    public let verify: RetryAfterGate
    public let realname: RetryAfterGate
    public let labor: RetryAfterGate

    public init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        read = RetryAfterGate(clock: clock)
        withdraw = RetryAfterGate(clock: clock)
        payout = RetryAfterGate(clock: clock)
        sms = RetryAfterGate(clock: clock)
        verify = RetryAfterGate(clock: clock)
        realname = RetryAfterGate(clock: clock)
        labor = RetryAfterGate(clock: clock)
    }

    public func reset() {
        for gate in [read, withdraw, payout, sms, verify, realname, labor] {
            gate.reset()
        }
    }
}

/// App 建一份、各页共用的依赖。
@MainActor
public final class WalletDeps {
    public let api: WalletApi
    public unowned let env: WalletEnv
    public let gates: WalletGates
    public let tokens: StepUpTokenCache
    public let cache: WalletCacheStore?
    /// 金额隐藏偏好（ClientCore 的 AmountMaskStore，与订单页同一份本机偏好，存储与键不变；G24）。
    public let mask: AmountMaskStore
    public let realname: RealNameBackend?
    public let labor: LaborBackend?
    public let texts: WalletTexts
    public var newKey: () -> String = { UUID().uuidString.lowercased() }
    /// 未决记录的结算通知（APP-09 共性第 1 条）。
    public let pending = WalletSignal<PendingSettled>()
    /// 二次验证发码的截止时间与在途占用（APP-09 共性第 6、17 条）。
    public let sms = SmsDeadlines()
    /// 钱包摘要的失效通知（APP-09 共性第 53、58、61 条）。
    public let walletDirty = WalletSignal<WalletOwner>()
    /// 写请求与发码的共享结算（会话级，共性第 66 条）：任务直接持有它结算，不经页面执行器。
    public let settlement: WalletSettlement

    public init(
        api: WalletApi, env: WalletEnv, gates: WalletGates, cache: WalletCacheStore?, mask: AmountMaskStore,
        realname: RealNameBackend?, labor: LaborBackend?, texts: WalletTexts = WalletDraftTexts()
    ) {
        self.api = api
        self.env = env
        self.gates = gates
        let tokens = StepUpTokenCache()
        self.tokens = tokens
        settlement = WalletSettlement(env: env, tokens: tokens)
        self.cache = cache
        self.mask = mask
        self.realname = realname
        self.labor = labor
        self.texts = texts
    }
}

/// 一条未决记录结算：所属账号与 operation。
public struct PendingSettled: Equatable, Sendable {
    public let account: String
    public let operationId: String
}

/// 主线程的广播（订阅返回取消闭包；订阅方出栈时取消）。
@MainActor
public final class WalletSignal<Value> {
    private var listeners: [Int: (Value) -> Void] = [:]
    private var next = 0

    public init() {}

    public func subscribe(_ listener: @escaping (Value) -> Void) -> () -> Void {
        next += 1
        let id = next
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    public func send(_ value: Value) {
        for listener in listeners.values {
            listener(value)
        }
    }

    public var listenerCount: Int {
        listeners.count
    }
}

/// 二次验证发码的截止时间与在途占用（APP-09 共性第 6、17、26、40 条，APP-05a 第 5、20、21 条）：按账号、规范化号码与 action 隔离；重开面板恢复
/// 倒计时，每次实际发送前检查同一截止时间；同一槽位同时只允许一个发码请求在途（防连点与跨面板交错）；在途结束、截止时间变化都发布（`changes`）。
/// 只在内存（进程内），会话换代时清空。
@MainActor
public final class SmsDeadlines {
    /// 一个发码槽位：账号、号码（只取数字）、action。
    public struct Slot: Hashable, Sendable {
        public let account: String
        public let phone: String
        public let action: String

        var id: String {
            "\(account)|\(phone.filter(\.isNumber))|\(action)"
        }
    }

    private var until: [String: Int64] = [:]
    private var sending: [String: Int] = [:]
    private var awaiting: Set<String> = []
    private var tickets = 0
    public let changes = WalletSignal<Void>()

    public init() {}

    public func remaining(_ slot: Slot, now: Int64) -> Int64 {
        max(0, (until[slot.id] ?? 0) - now)
    }

    public func start(_ slot: Slot, deadline: Int64) {
        until[slot.id] = deadline
        changes.send(())
    }

    /// 占用槽位：返回这次请求的票据；已有在途发码返回 nil。
    public func acquire(_ slot: Slot) -> Int? {
        guard sending[slot.id] == nil else { return nil }
        tickets += 1
        sending[slot.id] = tickets
        changes.send(())
        return tickets
    }

    /// 释放本次请求的占用：槽位已被清空（会话换代）或换成别的请求占用的，不动它。
    func awaitingIdentity(_ slot: Slot) -> Bool {
        awaiting.contains(slot.id)
    }

    func waitForIdentity(_ slot: Slot, ticket: Int) {
        guard sending[slot.id] == ticket else { return }
        awaiting.insert(slot.id)
        changes.send(())
    }

    public func release(_ slot: Slot, ticket: Int) {
        guard sending[slot.id] == ticket else { return }
        sending[slot.id] = nil
        awaiting.remove(slot.id)
        changes.send(())
    }

    public func busy(_ slot: Slot) -> Bool {
        sending[slot.id] != nil
    }

    public func clear() {
        until = [:]
        sending = [:]
        awaiting = []
        changes.send(())
    }
}

public extension WalletEnv {
    func check(_ owner: WalletOwner) -> IdentityCheck {
        isCurrent(owner) ? .current : .stale
    }

    func recheckIdentity() {}
}
