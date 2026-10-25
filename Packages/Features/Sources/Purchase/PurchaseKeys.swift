import DesignSystem
import Foundation
import ProductSearch
import Trade

/// 购买浮层、AuthSheet、JumpTip、授权管理用到的文案键（三端同名）。契约有的（buy.*、error.*、auth_manage.*、jump.taobao_sdk_unavailable、
/// no_rebate.price_compare.*、share_page.copy_tpwd.done）读契约字典；其余在 App 草稿表 TradeDraftTexts（TODO(N-28) 待定稿，不得提审）。
/// 本模块不出现中文。
public enum PurchaseKeys {
    public static let opening = "buy.opening"
    public static let openingCancel = "buy.opening.cancel"
    public static let timeout = "buy.timeout"
    public static let retry = "external_page.retry"
    public static let browserNotice = "trade.browser_notice"
    public static let priceChangedTitle = "trade.price_changed.title"
    public static let priceBefore = "trade.price_changed.before"
    public static let priceBeforePlain = "trade.price_changed.before_plain"
    public static let priceNow = "trade.price_changed.now"
    public static let priceNowPlain = "trade.price_changed.now_plain"
    public static let priceAsk = "trade.price_changed.ask"
    public static let couponGoneTitle = "trade.coupon_gone.title"
    public static let rebateGoneLine = "trade.rebate_gone.line"
    public static let rebateGoneNote = "trade.rebate_gone.note"
    public static let rebateGoneTitle = "trade.rebate_gone.title"
    public static let rebateGoneBody = "trade.rebate_gone.body"
    public static let rebateGoneBodyChanged = "trade.rebate_gone.body_changed"
    public static let rebateGoneBodyPlain = "trade.rebate_gone.body_plain"
    public static let cancel = "trade.cancel"
    public static let continueBuy = "trade.continue"
    public static let compareTitle = "no_rebate.price_compare.confirm"
    public static let compareBody = "trade.compare.body"
    public static let compareExplain = "trade.compare.explain"
    public static let compareReason = "no_rebate.price_compare"
    public static let similar = "no_rebate.price_compare.similar"
    public static let buyNoRebate = "trade.buy_no_rebate"
    public static let close = "trade.close"
    public static let authReason = "trade.auth.reason"
    public static let authPrivacy = "trade.auth.privacy"
    public static let authRebindNote = "auth_manage.rebind_note"
    public static let authGo = "auth_manage.action.authorize"
    public static let authDeclinedTitle = "trade.auth_declined.title"
    public static let authDeclinedBody = "trade.auth_declined.body"
    public static let authFailedTitle = "error.30104.credential_invalid"
    public static let authFailedBody = "trade.auth_failed.body"
    public static let authUnavailableBody = "trade.auth_unavailable.body"
    public static let authCheckRetry = "trade.auth_check.retry"
    public static let ok = "trade.ok"
    public static let jumpTipTitle = "trade.jump_tip.title"
    public static let jumpTipLine1 = "trade.jump_tip.line1"
    public static let jumpTipLine2 = "trade.jump_tip.line2"
    public static let jumpTipGo = "trade.jump_tip.go"
    public static let sdkFailedTitle = "jump.taobao_sdk_unavailable"
    public static let sdkFailedBody = "trade.sdk_failed.body"
    public static let notInstalled = "trade.not_installed"
    /// 淘宝未安装且本次走口令复制步骤后的主按钮字（G-D11 草稿键，三端同名，CT-16f）。
    public static let notInstalledCopyTpwd = "trade.not_installed.copy_tpwd"
    /// 50303 主按钮「稍后再试」（G-D09，复用草稿键 card.retry_later）。
    public static let retryLater = "card.retry_later"
    public static let contact = "trade.contact"
    public static let traceSuffix = "error.trace_suffix"
    public static let manageTitle = "auth_manage.title"
    public static let manageAuthorized = "auth_manage.status.authorized"
    public static let manageUnauthorized = "auth_manage.status.unauthorized"
    public static let manageBlocked = "error.30153"
    public static let back = "product.back"

    public static func platform(_ platform: String) -> String {
        "platform." + platform
    }
}

/// 文字拼装（平台名、金额、trace6）。
public struct PurchaseText {
    public let texts: SearchTexts

    public init(texts: SearchTexts) {
        self.texts = texts
    }

    public func platformName(_ platform: String) -> String {
        texts.text(PurchaseKeys.platform(platform))
    }

    public func text(_ key: String, platform: String = "", vars: [String: String] = [:]) -> String {
        var all = vars
        if !platform.isEmpty {
            all["platform_name"] = platformName(platform)
        }
        return all.isEmpty ? texts.text(key) : texts.format(key, all)
    }

    /// 带 trace6 的提示（03 §4.2）：文案里有 {trace6} 的填进去，没有的在正文后补「（xxxxxx）」；没有 trace 时用不带编号的文案。
    public func withTrace(_ key: String, platform: String, traceId: String?) -> String {
        let trace6 = TradeResults.trace6(traceId) ?? ""
        var message = text(key, platform: platform, vars: ["trace6": trace6])
        if message.isEmpty {
            message = text(SearchErrorText.genericKey, platform: platform, vars: ["trace6": trace6])
        }
        guard !trace6.isEmpty, !message.contains(trace6) else { return message }
        return message + texts.format(PurchaseKeys.traceSuffix, ["trace6": trace6])
    }

    /// 价格口径词（BR-PRICE-02 / 05：有券「券后」，无券「售价」；拼多多「拼单券后 / 拼单价」）。券额未知（改价、券失效后尚未补齐）
    /// 口径未定，返回 nil：不默认按有券写「券后」，也不把券后价称为无券售价（共性第 21、47 条）。
    public static func priceLabel(_ card: TradeObject) -> String? {
        guard RebateGoneBody.newPriceLabelKnown(card) else { return nil }
        let pdd = card["platform"] as? String == "pdd"
        let coupon = (card["coupon_fen"] as? NSNumber)?.int64Value
        if coupon == 0 {
            return pdd ? PriceTerms.pddPrice : PriceTerms.salePrice
        }
        return pdd ? PriceTerms.pddAfterCoupon : PriceTerms.afterCoupon
    }

    /// 「之前」行：原卡口径已知写「之前（券后 / 售价）」，未知写不带口径词的「之前」（共性第 47 条）。
    public func beforeLine(_ card: TradeObject) -> String {
        guard let label = Self.priceLabel(card) else { return text(PurchaseKeys.priceBeforePlain) }
        return text(PurchaseKeys.priceBefore, vars: ["price_label": label])
    }

    /// 「现在」行：新价口径已补齐写「现在（券后 / 售价）」，未补齐用 now_plain（共性第 21、30、37、45 条）。
    public func nowLine(_ card: TradeObject) -> String {
        guard let label = Self.priceLabel(card) else { return text(PurchaseKeys.priceNowPlain) }
        return text(PurchaseKeys.priceNow, vars: ["price_label": label])
    }

    /// 返利归零弹窗正文（BR-PRICE-13；共性第 45、47 条）。金额是否相同与口径是否已知分开判断：只有新旧金额相同才写「价格没有变化」，
    /// 原卡口径已知带口径词，未知用不带口径词的 body_plain；新价不同按新价口径写「现在（…）¥新」（未补齐用「现在」）；新价未知只说明
    /// 没有返利，不写价格。`before` 是这次点击时的卡，`after` 是按响应更新后的卡。
    public func rebateGoneBody(newFen: Int64?, oldFen: Int64?, before: TradeObject, after: TradeObject) -> String {
        switch RebateGoneBody.pick(newFen: newFen, oldFen: oldFen) {
        case .noPrice:
            return text(PurchaseKeys.rebateGoneNote)
        case let .unchanged(fen):
            let price = CouliFormat.money(fen: fen)
            guard let label = Self.priceLabel(before) else {
                return text(PurchaseKeys.rebateGoneBodyPlain, vars: ["price": price])
            }
            return text(PurchaseKeys.rebateGoneBody, vars: ["price_label": label, "price": price])
        case let .changed(fen):
            return text(PurchaseKeys.rebateGoneBodyChanged, vars: [
                "price_now": nowLine(after), "price": CouliFormat.money(fen: fen),
            ])
        }
    }
}
