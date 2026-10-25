import CouliNetwork
import Foundation

/// 购买浮层的阶段。
public enum PurchasePhase: String, Sendable {
    case idle
    /// open 请求在途：可取消的加载层（ProductBuyOpening，03 §4.5）。
    case loading
    /// 8 秒没有响应（ProductBuyTimeout，TRADE-22）：【重试】沿用原键。
    case timeout
}

/// 购买流程的弹层（每种对应设计稿一个画板）。
public enum PurchaseDialog: Equatable, Sendable {
    /// 价格变动（ProductPriceChanged）/ 券失效（`coupon`）确认；`rebateGone` 时合并无返利说明（ProductPriceChangedRebateGone）。
    case confirmPrice(oldFen: Int64?, newFen: Int64?, rebateGone: Bool, coupon: Bool)
    /// 返利变为 0（ProductRebateGone）。
    case confirmRebateGone(priceFen: Int64?, oldFen: Int64?)
    /// 比价无返利（ProductPriceCompareNoRebate，BR-PRICE-08）。
    case compareNoRebate
    /// 平台授权说明半屏（ProductAuthSheet）。
    case authSheet(platform: String, busy: Bool)
    /// 关闭授权（ProductAuthDeclined）/ 授权失败（`failed`，ProductAuthFailed）：【重试】【仍去购买（无返利）】（BR-ID-18）。
    case authDeclined(platform: String, failed: Bool)
    /// 授权结果查不到（共性第 19 条，03 §4.2）：授权回流后的查询、淘宝绑定或重新取授权地址请求失败（42901、5xxxx、传输失败），不知道
    /// 到底授权了没有，不能当成用户没授权。【重试】重新查询（42901 期间置灰、执行层也拦下）；【取消】放弃本次购买待办。
    case authCheckFailed(platform: String, textKey: String?, traceId: String?, afterBind: Bool)
    /// 站长授权不可用（ProductAuthUnavailable，BR-ID-24）：只提示，不给无返利购买。
    case authUnavailable(textKey: String?)
    /// 下单须知（ProductJumpTip，BR-ATTR-21）。
    case jumpTip(platform: String)
    /// 暂时无法打开淘宝（ProductJumpSdkFailed，BR-ATTR-27 淘宝行）。
    case sdkFailed
    /// 带按钮的错误提示（30103 / 30121 / 30151 / 30153 / 50303）。
    case notice(textKey: String?, traceId: String?, noRebate: Bool, contact: Bool, retry: Bool)

    /// 半屏（其余为居中弹窗）。比价无返利确认按定稿是居中弹窗（APP-06v G-D10），不在这里。
    public var isSheet: Bool {
        switch self {
        case .authSheet, .jumpTip: true
        default: false
        }
    }
}

/// 返利归零弹窗（ProductRebateGone）正文的写法（BR-PRICE-13；共性第 45 条）。价格变动未达阈值（price_changed=false）时新价可能
/// 与原价不同：只有新旧金额相同才写「价格没有变化」；新价不同按新价写「现在 ¥新」；新价未知不写价格。
public enum RebateGoneBody: Equatable, Sendable {
    /// 新旧金额相同：「价格没有变化，<原卡口径> ¥x」。
    case unchanged(priceFen: Int64)
    /// 新价与原价不同（或原价未知）：「现在（<新价口径>）¥新」，新价口径未补齐时用不带口径词的「现在」（now_plain）。
    case changed(priceFen: Int64)
    /// 新价未知：只说明继续购买不会获得返利。
    case noPrice

    public static func pick(newFen: Int64?, oldFen: Int64?) -> RebateGoneBody {
        guard let newFen else { return .noPrice }
        if let oldFen, oldFen == newFen {
            return .unchanged(priceFen: newFen)
        }
        return .changed(priceFen: newFen)
    }

    /// 新价的口径已补齐（卡片券额已知）：可写「现在（券后 / 售价）」；否则用 now_plain（共性第 21、37、45 条）。
    public static func newPriceLabelKnown(_ card: TradeObject?) -> Bool {
        card?["coupon_fen"] is NSNumber
    }
}

/// 轻提示（文案键 + trace6）。`id` 每次递增（同一句再次提示也重新播报）。
public struct PurchaseToast: Equatable, Sendable {
    public let key: String
    public let traceId: String?
    public let id: Int
}

/// 购买流程的界面状态。
public struct PurchaseState {
    public var phase: PurchasePhase = .idle
    public var platform = ""
    /// 最近一次点购买的卡（搜索页只给这张卡加按钮覆盖）。
    public var card: TradeObject?
    public var dialog: PurchaseDialog?
    /// 当前弹窗实例的票据（APP-08 iOS r3f NEW-02，APP-09 共性第 63 条）：每弹出一个弹窗换一张。页面在**渲染时**取出它，按钮回调把这份
    /// 不可变的值交回执行器；执行器只比较，旧回调拿着旧票据，碰不到之后出现的新弹窗。
    public internal(set) var dialogTicket: PurchaseDialogTicket?
    public var toast: PurchaseToast?
    /// 42901 限时禁用购买按钮与【重试】（Retry-After，缺省 5 秒）。
    public var rateLimited = false
    /// 全部路径失败、安装状态明确为 false：「安装X后下单才有返利」（ProductJumpNotInstalled，BR-ATTR-27 ②；unknown 不算，共性第 13 条）。
    public var notInstalled = false
    /// 淘宝明确未安装、且本次外跳的口令复制步骤已成功（APP-06v G-D11）：详情底栏上方常驻说明行、主按钮【复制淘口令】。只是展示标志，
    /// 与 `notInstalled` 同时置位、同时复位；再点仍走原购买流程（复制由服务端步骤执行）。
    public var notInstalledTpwd = false
    /// 即将交系统浏览器：「将通过浏览器打开X」+【取消】（ProductJumpBrowser）。
    public var browserNotice = false
    /// 当前这次加载层的编号（r3g NEW-02）：页面渲染时取出交给【取消】回调，旧加载层的回调取消不了新的加载。
    public internal(set) var loadingTicket: Int?
    /// 当前这次「将通过浏览器打开」提示的编号（r3g NEW-02），用法同上。
    public internal(set) var browserTicket: UInt64?

    public init() {}

    /// 这张卡此刻是不是本次购买的卡（搜索页逐卡判断加载态 / 超时条）。
    public func owns(_ item: TradeObject) -> Bool {
        guard let card else { return false }
        return CardPatch.sameCard(card, item)
    }
}

/// 弹窗实例票据（APP-08 iOS r3f NEW-02）：弹窗实例编号、产生它的尝试编号与那次尝试的固定来源。不可变，渲染时捕获。
public struct PurchaseDialogTicket: Equatable, Sendable {
    /// 弹窗实例编号（执行器内每弹出一次加 1）。
    public let serial: UInt64
    /// 产生弹窗的购买尝试的点击编号（没有尝试的弹窗为 nil）。
    public let click: Int?
    /// 产生弹窗的那次尝试固定的来源（`PurchaseAttempt.source.origin`）。
    public let origin: String?
}

/// 购买流程要的页面环境（App 给）。
@MainActor
public protocol PurchaseEnv: AnyObject {
    /// 有登录会话（游客 open 返回 10001）。
    func loggedIn() -> Bool
    /// 基本模式（没有同意完整隐私政策）：购买先走补同意，同意后按 pending_action 恢复一次（BR-ID-11、03 §4.1，共性第 4 条）。
    func basicMode() -> Bool
    /// 弹出补同意（首启弹窗的「开启完整功能」）。
    func requestConsent()
    /// 此刻的平台购买状态（点击结果确认的 50301 优先，其次 features.platform_status；on / maintenance / not_launched，缺失为 nil）。
    func platformStatus(_ platform: String) -> String?
    /// 点击结果确认的平台状态（50301 maintenance / not_launched，03 §7.4「点击时以响应为准」）：按平台记下，列表、详情的卡片映射与读屏
    /// 都按它；之后发出并生效的新配置覆盖它（共性第 5、6 条）。
    func markPlatformStatus(_ platform: String, status: String)
    /// 用 open 响应更新 `target` 这张卡（按 product_key 认；无论确认还是取消，BR-PRICE-12）。
    func updateCard(_ target: TradeObject, transform: @escaping (TradeObject) -> TradeObject)
    /// 经 Router 打开路由（Login、Search、Help，routes.json 的路由名）。
    func open(route: String, params: [String: String])
    /// 按 `target` 的 product_key + item_ref 重取权威商品卡（getProduct；之后仍须用户再点），结果到达时用 `merge`（此刻页面上的那张卡,
    /// 重取到的卡）→ 新卡 决定怎么落到页面上（共性第 17、26 条）。失败、页面已离开时什么都不做（卡片保持原样）。
    /// `request`：发起补齐的购买尝试固定的请求归属（`PurchaseAttempt.source.request`，APP-08 iOS r3f NEW-03），App 原样交给页面执行器
    /// 与网络层只比较，换号后零发送；nil = 不比较。
    func refetchCard(
        _ target: TradeObject, request: RequestOwnership?, merge: @escaping (TradeObject, TradeObject) -> TradeObject
    )
    /// 帮助入口（/v1/config.help_links.<key>：{route, params}），没有配置为 nil（不显示入口）。
    func helpLink(_ key: String) -> (route: String, params: [String: String])?
}

/// 一次购买尝试（不可变，共性第 1、2 条）：用户这一次点击的原卡快照（改价、返利归零确认的判断基准）、完整的原请求（路径里的 link_id、
/// 请求体、幂等键）。超时【重试】、登录后的重放都只重放它；迟到响应可以更新展示的卡片（含 new_link_id），但不改它，所以不会消除确认要求，
/// 也不会让重试打到别的路径。新点击、授权完成后才建新的尝试。
public final class PurchaseAttempt {
    public let click: Int
    /// 点击时的卡片快照。
    public let card: TradeObject
    /// 请求路径里的 link_id。
    public let linkId: String
    /// 请求体（JSON 文本）。
    public let body: String
    public let key: String
    public let noRebate: Bool
    public let noRebateReason: String?
    public let installed: String
    /// 用户在二选一里主动点【重试】发起的（拦下时直接给授权，不占自动弹出次数，共性第 10 条）。
    public let userAuthRetry: Bool
    /// 这次尝试的固定来源与请求归属（APP-08 iOS 第五次修复，APP-09 共性第 65 条）：首次发 open 时取一次（或由发起它的流程直接给出），
    /// 之后超时重试、授权查询 / 绑定 / 恢复、授权后的自动 open、它产生的弹窗都只用这一份——请求带着它交网络层比较，任何地方都不再读
    /// 当前会话来赋值。登录后重放是新尝试（`replay`），不继承。
    var source: JumpSource?

    init(
        click: Int, card: TradeObject, linkId: String, body: String, key: String, noRebate: Bool,
        noRebateReason: String?, installed: String, userAuthRetry: Bool
    ) {
        self.click = click
        self.card = card
        self.linkId = linkId
        self.body = body
        self.key = key
        self.noRebate = noRebate
        self.noRebateReason = noRebateReason
        self.installed = installed
        self.userAuthRetry = userAuthRetry
    }

    public var platform: String {
        TJSON.string(card["platform"]) ?? ""
    }

    /// 同一请求的重放（登录后）：新的点击编号，其余不变。
    func replay(click: Int) -> PurchaseAttempt {
        PurchaseAttempt(
            click: click, card: card, linkId: linkId, body: body, key: key, noRebate: noRebate,
            noRebateReason: noRebateReason, installed: installed, userAuthRetry: userAuthRetry
        )
    }
}

/// 文案键（契约有的读契约，没有的在 App 的草稿表 TradeDraftTexts，TODO(N-28)）。三端同名。
public enum PurchaseTextKeys {
    public static let maintenance = "error.50301.maintenance"
    public static let offShelf = "error.30141"
    public static let refExpired = "error.30144"
    public static let rateLimited = "error.42901"
    public static let generic = "error.50001"
    public static let network = "buy.timeout"
    public static let copied = "share_page.copy_tpwd.done"
    public static let notInstalledCopied = "trade.not_installed.copied"
    /// 淘宝未安装、口令已复制的轻提示「已复制淘口令」（APP-06v G-D11 草稿键，三端同名，CT-16f）。
    public static let notInstalledTpwdCopied = "trade.not_installed.tpwd_copied"
    public static let requote = "trade.requote_notice"
    public static let jumpFailed = "trade.jump_failed"
    public static let jumpExpired = "trade.jump_expired"
    public static let cancelledPrice = "trade.cancelled.price"
    public static let cancelledPriceRebate = "trade.cancelled.price_rebate"
    public static let cancelledRebate = "trade.cancelled.rebate"
}

/// 路由名（routes.json）。
public enum PurchaseRoutes {
    public static let login = "Login"
    public static let search = "Search"
    public static let help = "Help"
    public static let helpPriceCompare = "price_compare"
}
