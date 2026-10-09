import Combine
import CouliNetwork
import Foundation
import Generated
import TradeJump

/// 购买执行器（APP-06b；03 §4.5、§7.4，TRADE-03 / 22，BR-PRICE-08 / 12 / 13，BR-ATTR-21 / 27，BR-ID-10 / 11 / 17 / 18 / 22 / 24）。
/// 一个发起页一份，只在主线程使用。
///
/// - 点击：基本模式先补同意（登记 pending_action，同意后恢复一次）；按此刻的平台状态核对（maintenance 提示、not_launched 不发），
///   卡片已下架不发；再建一次 `PurchaseAttempt` 发 open（新键、可取消的加载层）。所有发 open 的入口（超时重试、登录重放、授权后、
///   无返利购买）都经 `send` 里同一个平台状态与可购核对（共性第 27 条）；
/// - 8 秒没有响应：结束加载，「网络不稳定，请重试」，【重试】完整重放原尝试（原路径、原请求体、原键）；不自动重试、不自动外跳；
/// - 续执行许可（共性第 3 条）：每次点击（及用户在确认框、超时条上的继续）发一张许可；取消、离开、进入后台或被覆盖、再次点击都作废它。
///   等 JumpTip 已读、浏览器提示、跳转每一步、上报 link_jump 之前都复核许可；作废之后到达的 open 响应只更新卡片，不外跳、不弹确认；
/// - 响应 → `OpenResponseAction`（判断基准是尝试的原卡快照）；卡片按响应更新，价格 / 返利字段给不全时重取权威卡片（不反推）；
///   错误 → `OpenErrorAction`；
/// - 10001：登记 pending_action（沿用原键）进登录，登录后 `resumeAfterLogin` 自动重放一次（不在前台时等回到前台）；
/// - 30101 / 30102 / 30111：AuthSheet（每平台每会话最多自动弹 2 次，BR-ID-18；用户在二选一里主动【重试】不受限）→ 授权 → 服务端确认已
///   授权后自动执行一次 open，用新键（BR-ID-10 / 22 细则）；取消、没完成或查不到授权 → 删除待办，给【仍去购买（无返利）】【重试】；
/// - 外跳：JumpTip（用户 × 平台首次）→ `TradeJumpExecutor`（每步上报 link_jump，同一个 attempt_id 与替换后的 link_id；expire_at 过期即停）。
@MainActor
public final class OpenPurchaseController: ObservableObject {
    /// TRADE-22：open 最多等 8 秒。
    public static let timeoutMillis: Int64 = 8000
    /// 「将通过浏览器打开」的提示停留时长（可取消；TODO(N-28) 未规定，A09 同口径 1.2 秒）。
    public static let browserNoticeMillis: Int64 = 1200
    static let spmMax = 128
    static let titleMax = 60
    static let openGroup = "open"
    static let authGroup = "auth"
    static let pageGroup = "page"

    @Published public internal(set) var state = PurchaseState()

    let calls: TradeCalls
    let executor: TradeJumpExecutor
    let ports: JumpPorts
    let env: PurchaseEnv
    let pending: PurchasePending
    let counter: AuthSheetCounter
    let tips: JumpTipService
    let webCode: WebCodeAuthorizer
    let baichuan: BaichuanAdapter
    let keyGenerator: () -> String
    let timeoutMillis: Int64
    let browserNoticeMillis: Int64
    let sleep: (Int64) async -> Void
    let gate: TradeRetryGate
    var keys: OpenAttempt

    /// 本页执行器的标识：购买待办按它归属（所有页面共用同一份待办记录，共性第 44 条）。
    let pageToken = UUID().uuidString.lowercased()
    /// 点击编号：每次新的点击（含授权后、登录后的自动执行）加 1。
    var click = 0
    /// 请求编号：超时【重试】是同一尝试的重发，旧请求的响应丢弃（新请求同键，结果相同）。
    var request = 0
    var interrupt = LateResponsePolicy.none
    var left = false
    /// 发起页在前台（可见、App 在前台、没有被别的页面盖住）。
    public internal(set) var foreground = true
    /// 自动执行的动作（授权、登录、补同意后的恢复）遇到页面不在前台：回到前台再执行。按恢复类型分槽，各类互不覆盖（共性第 48 条：
    /// 普通令牌刷新触发的登录恢复不得冲掉已排队的授权恢复）；回前台时按固定顺序逐类执行，每类执行前各自再核待办类型、归属与尝试。
    var deferred: [DeferredResume: () -> Void] = [:]
    var timer: Task<Void, Never>?
    var toastSeq = 0
    /// 当前的购买尝试。
    public internal(set) var current: PurchaseAttempt?
    /// 当前尝试那张卡的最新展示版本（按响应更新后的）。
    public internal(set) var card: TradeObject = [:]
    var spm: String?
    /// 续执行许可（共性第 3 条）。
    var permit: Permit?
    /// 最近一次成功响应（确认后外跳、比价弹窗用）。
    var ready: ReadyJump?
    /// 被授权码拦下的上下文。
    var authContext: AuthContext?
    var awaitingAuthReturn = false
    /// 授权完成、等回前台再自动 open 的那次授权（待办保留到真正执行前再核对、消费，共性第 46 条）；没有为 nil。
    var authResume: AuthContext?
    /// 用户点【去授权】发出的授权许可（进入后台即撤销；30104 恢复再拉起授权前核对，共性第 31 条）。
    var authPermit = false
    /// 进入后台的次数（外跳异步回调晚于回前台时据此补查授权，共性第 38 条）。
    var backgroundCount = 0
    /// 授权世代（共性第 20 条）：每次发出授权状态查询、开始一次授权流程、授权完成被消费、每次发出新的 open 请求都加 1。授权查询的归属、
    /// 授权流程的结果、授权完成后的延迟恢复都绑定发出时的世代与购买尝试；世代变了就作废（旧查询不得关掉新尝试的确认窗）。
    var authGen = 0
    var browserDecision: OneShot?
    /// 基本模式下点购买、等补同意的那张卡与 spm（原点击的报价基准，共性第 24 条）。
    var consentCard: (card: TradeObject, spm: String?)?
    /// 最近一次 open 响应对应尝试的原卡（确认框「之前」一行的价格口径词用）。
    public internal(set) var cardBeforeResponse: TradeObject = [:]

    /// 延迟恢复的类型（共性第 48 条）：每类一个槽位，同类后写覆盖先写，不同类互不影响。
    enum DeferredResume: CaseIterable {
        case auth
        case login
        case consent
    }

    final class Permit {
        let attempt: PurchaseAttempt
        var valid = true

        init(attempt: PurchaseAttempt) {
            self.attempt = attempt
        }
    }

    final class ReadyJump {
        let plan: TradeObject
        let identity: PurchaseIdentity
        let attempt: PurchaseAttempt

        init(plan: TradeObject, identity: PurchaseIdentity, attempt: PurchaseAttempt) {
            self.plan = plan
            self.identity = identity
            self.attempt = attempt
        }
    }

    final class AuthContext {
        let code: Int
        let linkId: String
        let data: TradeObject
        let attempt: PurchaseAttempt

        init(code: Int, linkId: String, data: TradeObject, attempt: PurchaseAttempt) {
            self.code = code
            self.linkId = linkId
            self.data = data
            self.attempt = attempt
        }

        var platform: String {
            attempt.platform
        }
    }

    public init(
        api: TradeApi,
        executor: TradeJumpExecutor,
        ports: JumpPorts,
        env: PurchaseEnv,
        pending: PurchasePending,
        counter: AuthSheetCounter,
        tips: JumpTipService,
        webCode: WebCodeAuthorizer,
        baichuan: BaichuanAdapter,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        keyGenerator: @escaping () -> String = { UUID().uuidString.lowercased() },
        timeoutMillis: Int64 = OpenPurchaseController.timeoutMillis,
        browserNoticeMillis: Int64 = OpenPurchaseController.browserNoticeMillis,
        sleep: @escaping (Int64) async -> Void = { millis in
            try? await Task.sleep(nanoseconds: UInt64(max(0, millis)) * 1_000_000)
        }
    ) {
        calls = TradeCalls(api: api)
        self.executor = executor
        self.ports = ports
        self.env = env
        self.pending = pending
        self.counter = counter
        self.tips = tips
        self.webCode = webCode
        self.baichuan = baichuan
        self.keyGenerator = keyGenerator
        self.timeoutMillis = timeoutMillis
        self.browserNoticeMillis = browserNoticeMillis
        self.sleep = sleep
        gate = TradeRetryGate(clock: clock)
        keys = OpenAttempt(keyGenerator: keyGenerator)
    }

    /// 在途的 open 请求数（测试核对取消）。
    public var inFlightOpens: Int {
        calls.count(group: Self.openGroup)
    }

    /// 页面已离开（出栈）。
    public var isLeft: Bool {
        left
    }

    /// 购买按钮此刻可点（限流、在途、有弹层时不可点）。
    public var canTap: Bool {
        !left && !busy && !gate.active
    }
}

/// 只能完成一次的等待（浏览器提示：取消 / 到时，先到先得）。
@MainActor
final class OneShot {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
