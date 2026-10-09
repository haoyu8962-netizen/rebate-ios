import Foundation
import Generated

/// open 响应 → 卡片（BR-PRICE-12、03 §7.4「无论确认还是取消，都用新价格与 new_link_id 替换卡片」）。只写响应确定的字段，不反推
/// （APP-06b 共性第 7、8 条，BR-PRICE-17）：
/// - new_link_id 替换 link_id；quoted_at 换新；availability=off_shelf 照写；
/// - 券后价变了：final_price_fen 换新，券前价与券额响应没有 → 置未知（null，不用旧券额反推）；coupon_gone 只说明原券失效、不等于当前无券
///   （可能换了新券，BR-PRICE-14，共性第 21 条）：同样置未知，先去掉「有券」、按钮「领券购买」改「去购买」，重取补齐券额后 `fill` 再同步；
///   两种都把预估返后置未知；
/// - 返利上限由 > 0 变为 0 → 暂无返利（rebate_basis=no_rebate、按钮「去购买（无返利）」、no_rebate_cause 原样），去掉返利口径句；
/// - 返利由 0 变为正数：清掉暂无返利的状态、原因与「去购买（无返利）」（口径响应没有 → rebate_basis 置未知，并标临时展示状态
///   `provisionalRebate`：按服务端区间显示，共性第 16 条）；其余返利变化换新区间；预估返后置未知。金额未知（null）保持未知、不补 0。
/// 改价、券失效、返利变化（不含变为 0）时 `needsRefetch`：调用方按 product_key + item_ref 重取权威卡片，用 `fill` 只补齐仍未知的字段
/// （共性第 17、26 条：补齐请求带卡片版本）；30144 用 `reload` 整卡替换但不覆盖之后写入的购买结果（卡片版本 `revision`）。
public enum CardPatch {
    /// 卡片版本的客户端字段名（不来自接口，不上送）。
    public static let revisionKey = "client_card_rev"
    /// 价格待补齐（新券后价已知、券前价与券额未知，共性第 34 条）。客户端字段，不上送；补齐后去掉。
    public static let pricePendingKey = "client_price_pending"
    /// 返利临时展示状态（返利由 0 变正、口径未知时按服务端区间显示，共性第 16 条）。客户端字段，不上送。
    public static let provisionalKey = "client_provisional_rebate"
    /// 「有券」标签（benefit_tags 的契约示例取值）。
    public static let hasCouponTag = "有券"
    static let buyCoupon = "btn.buy.coupon"
    static let buy = "btn.buy"
    static let buyNoRebate = "btn.buy.no_rebate"
    static let rangeBases: Set<String> = [RebateBasis.normal.rawValue, RebateBasis.priceCompareRisk.rawValue]
    static let rebatePrefix = "rebate_"

    public static func apply(_ card: TradeObject, _ data: TradeObject) -> TradeObject {
        var out = card
        if let link = TJSON.string(data["new_link_id"]) {
            out["link_id"] = link
        }
        let couponGone = TJSON.string(data["availability"]) == Availability.couponGone.rawValue
        if priceChanged(card, data) {
            out["final_price_fen"] = TJSON.fen(data["new_final_price_fen"]).map { NSNumber(value: $0) } ?? NSNull()
            // 券前价与券额响应不带：一律置未知（coupon_gone 只说明原券失效，不等于当前无券，共性第 21 条），等重取补齐
            out["coupon_fen"] = NSNull()
            out["price_fen"] = NSNull()
            out["est_net_price_fen"] = NSNull()
            // 新券后价已知、券前价与券额待补齐：卡片照常显示已知新价并可购买，不当价格不可用（共性第 34 条）
            out[pricePendingKey] = TJSON.fen(data["new_final_price_fen"]) != nil ? true : nil
            if couponGone {
                out["benefit_tags"] = TJSON.strings(card["benefit_tags"]).filter { $0 != hasCouponTag }
                if var cta = TJSON.object(card["cta"]), TJSON.string(cta["text_key"]) == buyCoupon {
                    cta["text_key"] = buy
                    out["cta"] = cta
                }
            }
        }
        applyRebate(&out, card, data)
        if let quoted = TJSON.string(data["quoted_at"]) {
            out["quoted_at"] = quoted
        }
        if TJSON.string(data["availability"]) == Availability.offShelf.rawValue {
            out["availability"] = Availability.offShelf.rawValue
        }
        return out
    }

    /// 返利字段（BR-PRICE-13、BR-PRICE-08；共性第 8、16、22、35 条）。
    static func applyRebate(_ out: inout TradeObject, _ card: TradeObject, _ data: TradeObject) {
        let newMax = TJSON.fen(data["new_rebate_max_fen"])
        let newMin = TJSON.fen(data["new_rebate_min_fen"])
        let oldMax = TJSON.fen(card["rebate_max_fen"])
        let basis = TJSON.string(card["rebate_basis"])
        // amount_unknown 卡不复核返利（BR-PRICE-08）：响应为 null 时保持原样
        if basis == TradeConstants.amountUnknown, newMax == nil {
            return
        }
        let alreadyZero = oldMax == 0 && basis == RebateBasis.noRebate.rawValue
            && TJSON.string(TJSON.object(card["cta"])?["text_key"]) == buyNoRebate
        if newMax == 0, !alreadyZero {
            // 确定返利为 0（含返利由正变 0、游客未知 → 登录后重放得到 0，共性第 41 条）：零金额、暂无返利、无返利按钮与原因
            out["rebate_min_fen"] = NSNumber(value: 0)
            out["rebate_max_fen"] = NSNumber(value: 0)
            out["rebate_basis"] = RebateBasis.noRebate.rawValue
            out[provisionalKey] = nil
            out["est_net_price_fen"] = NSNull()
            out["no_rebate_cause"] = TJSON.string(data["no_rebate_cause"]) == NoRebateCause.priceCompare.rawValue
                ? NoRebateCause.priceCompare.rawValue : NSNull()
            out["cta"] = ["text_key": buyNoRebate]
            out["disclaimer_keys"] = TJSON.strings(card["disclaimer_keys"]).filter { !$0.hasPrefix(rebatePrefix) }
        } else if newMax == 0 {
            // 零返利保持为零：也按本次响应更新比价原因（共性第 35 条；空或未知值清除原因与相似入口）
            out["no_rebate_cause"] = TJSON.string(data["no_rebate_cause"]) == NoRebateCause.priceCompare.rawValue
                ? NoRebateCause.priceCompare.rawValue : NSNull()
        } else if let newMax, let newMin, newMax != oldMax || newMin != TJSON.fen(card["rebate_min_fen"]) {
            out["rebate_min_fen"] = NSNumber(value: newMin)
            out["rebate_max_fen"] = NSNumber(value: newMax)
            out["est_net_price_fen"] = NSNull()
            if newMax > 0, restored(card) {
                // 返利从无到有：不留「暂无返利 / 去购买（无返利）」与比价原因；口径响应没有 → 置未知并标临时展示状态，按服务端区间显示，
                // 等重取的权威卡片补口径；重取失败就一直按区间显示，不落入「暂无返利」（共性第 8、16 条）
                out["rebate_basis"] = NSNull()
                out[provisionalKey] = true
                out["no_rebate_cause"] = NSNull()
                // 券额未知（同时改价）与确定无券不同（共性第 22 条）：未知时先给「去购买」，补齐后由 `fill` 按实际券额同步为「领券购买」
                let coupon = TJSON.fen(out["coupon_fen"])
                out["cta"] = ["text_key": (coupon ?? 0) > 0 ? buyCoupon : buy]
            }
        }
    }

    /// 这次响应会不会改变卡片的价格、返利、link 或可购状态（取价时间除外）。同键重放得到相同结果时为 false（共性第 33 条）。
    public static func changes(_ card: TradeObject, _ data: TradeObject) -> Bool {
        var before = card
        var after = apply(card, data)
        before["quoted_at"] = nil
        after["quoted_at"] = nil
        return TJSON.encode(before) != TJSON.encode(after)
    }

    /// 响应给不全卡片要的字段（券前价、券额、预估返后、返利口径），要按 product_key + item_ref 重取权威卡片（共性第 7、8 条）。
    public static func needsRefetch(_ card: TradeObject, _ data: TradeObject) -> Bool {
        if priceChanged(card, data) {
            return true
        }
        guard let newMax = TJSON.fen(data["new_rebate_max_fen"]), let newMin = TJSON.fen(data["new_rebate_min_fen"]),
              newMax != 0
        else { return false }
        return newMax != TJSON.fen(card["rebate_max_fen"]) || newMin != TJSON
            .fen(card["rebate_min_fen"]) || restored(card)
    }

    /// 同一张卡：product_key 相同（换了 link_id 也认得出）；没有 product_key 时按 link_id。
    public static func sameCard(_ lhs: TradeObject, _ rhs: TradeObject) -> Bool {
        if let key = TJSON.string(lhs["product_key"]) {
            return key == TJSON.string(rhs["product_key"])
        }
        return TJSON.string(lhs["link_id"]) != nil && TJSON.string(lhs["link_id"]) == TJSON.string(rhs["link_id"])
    }

    static func priceChanged(_ card: TradeObject, _ data: TradeObject) -> Bool {
        guard let newFinal = TJSON.fen(data["new_final_price_fen"]) else { return false }
        return newFinal != TJSON.fen(card["final_price_fen"])
            || (TJSON.string(data["availability"]) == Availability.couponGone.rawValue
                && TJSON.fen(card["coupon_fen"]) != nil)
    }

    /// 补齐价格字段（共性第 17、26 条）：`current` 是此刻页面上的卡（已写入本次 open 确认的结果），`fresh` 是重取到的权威卡。
    /// `expected` 是发出补齐请求时卡片的版本：版本已变（之后又写进了新的购买结果）就不补，旧的补齐响应不得填入新一次购买结果的字段。
    /// 详情 / 搜索接口的报价不带本次 open 的比价预判（BR-PRICE-07 / 13），不能整卡替换：
    /// - link_id、返利区间、返利口径（含 no_rebate）、no_rebate_cause、按钮、可购状态、取价时间一律保留 `current` 的；
    /// - 券前价、券额只在此刻仍未知、且 `fresh` 的券后价与 `current` 一致时补上；券额由未知补成已知时同步「有券」标签与普通购买按钮
    ///   （领券购买 / 去购买，共性第 21、22 条），「去购买（无返利）」不动；
    /// - 临时展示状态：`fresh` 的区间与 `current` 一致且口径为 normal / price_compare_risk 时补上口径（连同返利口径句）、去掉临时标记；
    /// - 预估返后只在仍未知、价格与区间都一致、口径相同时补上。
    public static func fill(expected: Int64) -> (TradeObject, TradeObject) -> TradeObject {
        { current, fresh in
            guard revision(current) == expected else { return current }
            return fill(current, fresh)
        }
    }

    static func fill(_ current: TradeObject, _ fresh: TradeObject) -> TradeObject {
        if let key = TJSON.string(current["product_key"]), let freshKey = TJSON.string(fresh["product_key"]),
           key != freshKey {
            return current
        }
        var out = current
        let final = TJSON.fen(current["final_price_fen"])
        let samePrice = final != nil && TJSON.fen(fresh["final_price_fen"]) == final
        let missing = samePrice ? ["price_fen", "coupon_fen"].filter { TJSON.fen(current[$0]) == nil } : []
        for field in missing {
            if let value = TJSON.fen(fresh[field]) {
                out[field] = NSNumber(value: value)
            }
        }
        if missing.contains("coupon_fen"), let coupon = TJSON.fen(fresh["coupon_fen"]) {
            syncCoupon(&out, hasCoupon: coupon > 0)
        }
        if TJSON.fen(out["price_fen"]) != nil, TJSON.fen(out["coupon_fen"]) != nil {
            out[pricePendingKey] = nil
        }
        let low = TJSON.fen(current["rebate_min_fen"])
        let high = TJSON.fen(current["rebate_max_fen"])
        let sameRebate = low != nil && high != nil
            && TJSON.fen(fresh["rebate_min_fen"]) == low && TJSON.fen(fresh["rebate_max_fen"]) == high
        let freshBasis = TJSON.string(fresh["rebate_basis"])
        if provisional(current), sameRebate, let freshBasis, rangeBases.contains(freshBasis) {
            out["rebate_basis"] = freshBasis
            out[provisionalKey] = nil
            let kept = TJSON.strings(current["disclaimer_keys"]).filter { !$0.hasPrefix(rebatePrefix) }
            let rebateKeys = TJSON.strings(fresh["disclaimer_keys"]).filter { $0.hasPrefix(rebatePrefix) }
            out["disclaimer_keys"] = kept + rebateKeys
        }
        let basis = TJSON.string(out["rebate_basis"])
        if TJSON.fen(current["est_net_price_fen"]) == nil, samePrice, sameRebate, let basis, rangeBases.contains(basis),
           basis == freshBasis, let est = TJSON.fen(fresh["est_net_price_fen"]) {
            out["est_net_price_fen"] = NSNumber(value: est)
        }
        return out
    }

    /// 重新加载（30144，共性第 9、17 条）：整卡换成权威卡，但请求发出时卡片版本是 `expected`、到达时版本已变（之后又写进了购买结果）
    /// 就不覆盖，保留新的。
    public static func reload(expected: Int64) -> (TradeObject, TradeObject) -> TradeObject {
        { current, fresh in
            guard revision(current) == expected else { return current }
            var out = fresh
            out[revisionKey] = NSNumber(value: expected + 1)
            return out
        }
    }

    /// 卡片版本（客户端字段，每写入一次购买结果加 1；接口的卡没有 = 0）。
    public static func revision(_ card: TradeObject) -> Int64 {
        TJSON.fen(card[revisionKey]) ?? 0
    }

    /// 版本加 1。
    public static func bump(_ card: TradeObject) -> TradeObject {
        var out = card
        out[revisionKey] = NSNumber(value: revision(card) + 1)
        return out
    }

    /// 价格待补齐（共性第 34 条）。
    public static func pricePending(_ card: TradeObject) -> Bool {
        TJSON.flag(card[pricePendingKey])
    }

    /// 返利临时展示状态（共性第 16 条）。
    public static func provisional(_ card: TradeObject) -> Bool {
        TJSON.flag(card[provisionalKey])
    }

    /// 按已确认的券额同步「有券」标签与普通购买按钮（「领券购买」↔「去购买」）；其它按钮（含「去购买（无返利）」）不动。
    static func syncCoupon(_ out: inout TradeObject, hasCoupon: Bool) {
        let tags = TJSON.strings(out["benefit_tags"]).filter { $0 != hasCouponTag }
        out["benefit_tags"] = hasCoupon ? [hasCouponTag] + tags : tags
        guard var cta = TJSON.object(out["cta"]) else { return }
        let key = TJSON.string(cta["text_key"])
        if key == buy || key == buyCoupon {
            cta["text_key"] = hasCoupon ? buyCoupon : buy
            out["cta"] = cta
        }
    }

    /// 卡片原来是暂无返利。
    /// 卡片原来没有确定的正返利：暂无返利，或游客「登录后查看返利」/ 金额未知（共性第 41 条：变为正数时清掉 login_required，
    /// 先按服务端区间显示再补齐口径）。
    static func restored(_ card: TradeObject) -> Bool {
        let basis = TJSON.string(card["rebate_basis"])
        return basis == RebateBasis.noRebate.rawValue || basis == RebateBasis.loginRequired.rawValue
            || TJSON.fen(card["rebate_max_fen"]) == 0 || TJSON.fen(card["rebate_max_fen"]) == nil
    }
}
