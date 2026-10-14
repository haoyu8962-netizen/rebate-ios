import CouliNetwork
import Foundation
import Generated

/*
 APP-06b 购买流程的纯逻辑（三端同名；向量 specs/open-trade-vectors.json，测试 Features/Tests/TradeTests/OpenTradeVectorTests）。
 执行器（OpenPurchaseController、TradeJumpExecutor）直接调用这些函数，向量测到的就是生产判定。规则空白按保守处理（不外跳、
 不放行），标 TODO(N-28)。
 */

/// 一次购买尝试的 Idempotency-Key 生命周期（拍板第二批 TRADE-22、BR-ID-10 细则「恢复执行时用哪个幂等键」）：
/// - `start`：一次新的点击（含取消、离开后再点）→ 新键；
/// - `timeout` / `retry`：8 秒超时后的【重试】是同一次点击的重发 → 原键；
/// - `authRequired`（30101 / 30102 / 30111）后 `resendAfterAuth`：授权后再发是新请求 → 新键（3xxxx 已写入幂等记录）；
/// - 10001 登录后的重放沿用原键（1xxxx 不写幂等记录），用 `retry`；
/// - `abandon` / `cancel` 只是本机放弃：open 不属于作废接口的四类 step-up 操作，不调 abandonIdempotencyKey（`abandonCalled` 恒为 false）。
public struct OpenAttempt {
    private let keyGenerator: () -> String
    /// 当前（最近一次发送用的）键；还没点过为 nil。
    public private(set) var currentKey: String?
    /// 被授权码拦下、等授权完成（之后 `resendAfterAuth` 换新键）。
    public private(set) var awaitingAuth = false

    public init(keyGenerator: @escaping () -> String) {
        self.keyGenerator = keyGenerator
    }

    /// 是否调了服务端作废接口：open 不在作废接口的四类操作里，恒为 false（向量 abandon_open_is_local_only）。
    public var abandonCalled: Bool {
        false
    }

    /// 新的点击：新键。
    @discardableResult
    public mutating func start() -> String {
        fresh()
    }

    /// 8 秒没有响应：键不变（等用户点【重试】）。
    public mutating func timeout() {}

    /// 同一请求的重发（超时【重试】、登录后的重放）：沿用原键；还没有键时等同 `start`。
    @discardableResult
    public mutating func retry() -> String {
        currentKey ?? fresh()
    }

    /// 被 30101 / 30102 / 30111 拦下。
    public mutating func authRequired(code _: Int) {
        awaitingAuth = true
    }

    /// 授权完成后重新发起同一 link 的 open：新请求、新键。
    @discardableResult
    public mutating func resendAfterAuth() -> String {
        awaitingAuth = false
        return fresh()
    }

    /// 用户取消：只挡本机外跳，服务端的点击证据与幂等结果照常保留（03 §4.5），不作废键。
    public mutating func cancel() {}

    /// 本机放弃（超时后不重试）：不调作废接口。
    public mutating func abandon() {}

    private mutating func fresh() -> String {
        let key = keyGenerator()
        currentKey = key
        return key
    }
}

/// open 成功响应 → 客户端动作（03 §7.4 表）。`actionRaw` 是三端统一的接线标签。
public struct OpenResponseOutcome: Equatable, Sendable {
    public var actionRaw: String
    /// 带 new_link_id 时立即替换卡片（不等确认 / 取消，BR-PRICE-12）。
    public var replaceLinkId: String?
    /// requote_failed=true：照常外跳，同时提示价格以下单页为准（BR-PRICE-13）。
    public var requoteNotice: Bool
    /// 返利由 > 0 变为 0（new_rebate_max_fen = 0，BR-PRICE-13）：改价 / 券失效的确认框里追加无返利说明。
    public var rebateGone = false
    public var oldFinalFen: Int64?
    public var newFinalFen: Int64?
}

/// open 响应动作标签。
public enum OpenActions {
    public static let jump = "jump"
    public static let confirmPrice = "confirm_price"
    public static let confirmRebateGone = "confirm_rebate_gone"
    public static let confirmCoupon = "confirm_coupon"
    public static let compareNoRebate = "compare_no_rebate"
    /// availability=off_shelf：不外跳、卡片置灰（30141 同义；向量未覆盖，G07）。
    public static let offShelf = "off_shelf"
}

/// open 成功响应 → 动作（03 §7.4、BR-PRICE-08 / 12 / 13 / 14）。多种同时成立时 off_shelf > coupon_gone > price_changed（03 §7.4），
/// 返利归零与改价、券失效合并在同一个确认框里（`rebateGone`）；没有改价只有返利归零时：no_rebate_cause=price_compare 弹比价无返利
/// （BR-PRICE-08，替代通用无返利确认），其余（含未知原因，按 null）弹无返利确认。amount_unknown（context.amountUnknown=true）不做
/// 价格复核提示（BR-PRICE-08）。金额读成 Int64，null 保持未知、不补 0。
///
/// context：{ currentPriceFen, currentRebateMaxFen, amountUnknown, noRebateConfirmed }（这次点击时卡片的值；noRebateConfirmed =
/// 这次是用户已确认的无返利购买）。
public enum OpenResponseAction {
    public static func map(response: TradeObject, context: TradeObject) -> OpenResponseOutcome {
        let data = TJSON.object(response["data"]) ?? [:]
        let availability = TJSON.string(data["availability"])
        var base = OpenResponseOutcome(
            actionRaw: OpenActions.jump,
            replaceLinkId: TJSON.string(data["new_link_id"]),
            requoteNotice: TJSON.flag(data["requote_failed"]),
            oldFinalFen: TJSON.fen(data["old_final_price_fen"]),
            newFinalFen: TJSON.fen(data["new_final_price_fen"])
        )
        if availability == Availability.offShelf.rawValue {
            base.actionRaw = OpenActions.offShelf
            return base
        }
        if TJSON.flag(context["amountUnknown"]) {
            return base
        }
        let before = TJSON.fen(context["currentRebateMaxFen"])
        let after = TJSON.fen(data["new_rebate_max_fen"])
        let rebateGone = (before ?? 0) > 0 && after == 0
        // 比价无返利（BR-PRICE-08）只按本次响应与本次请求判定，完全不看原返利（共性第 43 条）：原返利为正、为 0 或未知（游客
        // login_required、null）时，本次返回零返利 + price_compare 都要确认；只有这次就是用户确认过的无返利购买（no_rebate=true）时不再问
        let compare = after == 0 && TJSON.string(data["no_rebate_cause"]) == NoRebateCause.priceCompare.rawValue
            && !TJSON.flag(context["noRebateConfirmed"])
        let lost = rebateGone || compare
        if availability == Availability.couponGone.rawValue {
            base.actionRaw = OpenActions.confirmCoupon
            base.rebateGone = lost
        } else if TJSON.flag(data["price_changed"]) {
            base.actionRaw = OpenActions.confirmPrice
            base.rebateGone = lost
        } else if compare {
            base.actionRaw = OpenActions.compareNoRebate
            base.rebateGone = true
        } else if rebateGone {
            base.actionRaw = OpenActions.confirmRebateGone
            base.rebateGone = true
        }
        return base
    }
}

/// open 错误码 → 动作。
public struct OpenErrorOutcome: Equatable, Sendable {
    public var actionRaw: String
    public var textKey: String?
    public var showTrace6: Bool
    /// 50301 not_launched：购买按钮置灰、不弹 Toast（error-codes 50301）。
    public var silent = false
    /// 给【仍去购买（无返利）】（30103、30121、30151、30153、50303，BR-ID-18、BR-PRICE-08）。
    public var offerNoRebate = false
    /// 给【联系客服】（30103、30151、30153）。
    public var offerContact = false
    /// 给【重试】（50303 主按钮）。
    public var offerRetry = false
}

/// open 错误动作标签。
public enum OpenErrorActions {
    public static let login = "login"
    public static let authSheet = "auth_sheet"
    public static let authJump = "auth_jump"
    public static let notice = "notice"
    public static let error = "error"
    public static let retryAfter = "retry_after"
    /// 30143：引导重新搜索（向量未覆盖，G08）。
    public static let research = "research"
    /// 30144：按卡片 product_key + item_ref 重取卡片，之后仍须用户再点（G08）。
    public static let refetch = "refetch"
    /// 10405：强更 / 受限会话刷新由网络层与外壳处理，页面只结束加载（G08）。
    public static let forceUpdate = "force_update"
}

/// open 错误码 → 动作（error-codes.json、03 §7.4、BR-ID-17 / 18 / 22 / 24）。文案键 error.<code>.<reason> 回落 error.<code>
/// （BR-TEXT-14，ErrorActionMapper.resolveTextKey）；5xxxx 带 trace6。auth_unavailable 只提示，不拉起授权、不给无返利购买（BR-ID-24）。
public enum OpenErrorAction {
    public static func map(
        code: Int, data: TradeObject, hasText: (String) -> Bool = { DefaultTexts.text($0) != nil }
    ) -> OpenErrorOutcome {
        let reason = TJSON.string(data["reason"])
        let key = ErrorActionMapper.resolveTextKey(code: code, reason: reason, hasText: hasText)
        if let outcome = purchaseOutcome(code: code, reason: reason, key: key) {
            return outcome
        }
        let serverError = (50000...59999).contains(code)
        switch code {
        case 50301:
            return OpenErrorOutcome(
                actionRaw: OpenErrorActions.notice, textKey: key, showTrace6: true,
                silent: reason == TradeConstants.notLaunched
            )
        case 50303:
            return OpenErrorOutcome(
                actionRaw: OpenErrorActions.error, textKey: key, showTrace6: true, offerNoRebate: true, offerRetry: true
            )
        case 42901:
            return OpenErrorOutcome(actionRaw: OpenErrorActions.retryAfter, textKey: key, showTrace6: false)
        case 10405:
            return OpenErrorOutcome(actionRaw: OpenErrorActions.forceUpdate, textKey: nil, showTrace6: false)
        default:
            return OpenErrorOutcome(
                actionRaw: serverError ? OpenErrorActions.error : OpenErrorActions.notice, textKey: key,
                showTrace6: serverError
            )
        }
    }

    /// 1xxxx / 3xxxx 购买业务码（登录、授权、渠道受阻、商品状态）。其余码为 nil。
    private static func purchaseOutcome(code: Int, reason: String?, key: String?) -> OpenErrorOutcome? {
        let simple: [Int: String] = [
            10001: OpenErrorActions.login, 30141: OpenErrorActions.error,
            30143: OpenErrorActions.research, 30144: OpenErrorActions.refetch,
        ]
        if let action = simple[code] {
            return OpenErrorOutcome(actionRaw: action, textKey: key, showTrace6: false)
        }
        switch code {
        case 30101, 30102, 30111:
            // 30101 / 30102 的 auth_unavailable 只提示（BR-ID-24）；生成表按 reason 规定不能补办后重试的（sharer_auth_invalid=never，
            // CT-LOCK-01）同样只提示：不弹授权、不登记待办、不重放、不给无返利购买（契约数据驱动，与鸿蒙 / Android 同口径；
            // link_landing.invalid 专门展示归 APP-13b）。表里没有的 reason 与无 reason 走原授权动作
            let promptOnly = (code != 30111 && reason == TradeConstants.authUnavailable)
                || ErrorActionMapper.promptOnlyReason(code: code, reason: reason)
            let action = promptOnly
                ? OpenErrorActions.notice
                : (code == 30111 ? OpenErrorActions.authJump : OpenErrorActions.authSheet)
            return OpenErrorOutcome(actionRaw: action, textKey: key, showTrace6: false)
        case 30103, 30151, 30153:
            return OpenErrorOutcome(
                actionRaw: OpenErrorActions.notice, textKey: key, showTrace6: false, offerNoRebate: true,
                offerContact: true
            )
        case 30121:
            return OpenErrorOutcome(
                actionRaw: OpenErrorActions.notice, textKey: key, showTrace6: false, offerNoRebate: true
            )
        default:
            return nil
        }
    }
}

/// 迟到响应的处理：是否允许继续外跳流程、是否用它更新卡片。
public struct LateDecision: Equatable, Sendable {
    public let jump: Bool
    public let updateCard: Bool
}

/// 取消、离开发起页、App 进入后台之后才到达的 open 响应：只更新卡片（新价格、new_link_id、无返利状态），不外跳、不弹确认、
/// 不上报 link_jump（03 §4.5）。这里只判「仍属于最近一次点击」的响应；更早点击的响应由执行器按请求编号直接丢弃。
public enum LateResponsePolicy {
    public static let none = "none"
    public static let cancel = "cancel"
    public static let leave = "leave"
    public static let background = "background"

    public static func decide(interrupt: String) -> LateDecision {
        LateDecision(jump: interrupt == none, updateCard: true)
    }
}
