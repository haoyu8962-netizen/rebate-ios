import Foundation
import Generated

// MARK: - 详情

/// 详情页模型的原始判定（显示文字由页面经 DesignSystem 格式化）。
public struct ProductDetailView: Equatable, Sendable {
    /// 购买按钮文案键：服务端 cta.text_key 原样（BR-TEXT-12、TRADE-21：客户端不自己决定）；缺失为空串。
    public let buttonKeyRaw: String
    /// 预售（is_presale，BR-PRICE-22）：「预售」标签与说明。
    public let presale: Bool
    /// 可返利、金额未知（rebate_basis=amount_unknown，BR-PRICE-08、TRADE-08）。
    public let rebateUnknown: Bool
    /// 降级卡（ProductCardDegrade）。TODO(N-27)：getProduct 没有平台状态与认领配置，stale 也不等于画板的五种能力降级；
    /// 判定不了，恒为 false（不显示降级卡）。
    public let degraded: Bool
    /// 返利消失（ProductRebateGone）。TODO(N-27)：只有 open 复核时返利由正变 0 才算（BR-PRICE-13），在 APP-06b 判；恒为 false。
    public let rebateGone: Bool
    /// 公开态：游客或基本模式（不表示公开发布版本的分享入口）。
    public let publicMode: Bool
    /// 购买按钮可点：有按钮文案键，且不是已下架、价格不可用（BR-PRICE-21、BR-PRICE-01）。
    /// TODO(N-27)：下架与价格不可用的按钮文案键未规定，按钮置灰。
    public let buyEnabled: Bool
    /// 缓存 / 商品池降级报价（stale=true 或 age_sec > 300，BR-PRICE-11）：取价处提示价格可能已变化。不是降级卡。
    public let stale: Bool
    /// 价格不可用（BR-PRICE-01）：availability=price_unavailable，或价格三字段任一缺失（amount_unknown 卡除外）。
    /// 不显示任何金额、不补 0。
    public let priceUnavailable: Bool
}

/// getProduct 的 ProductCard → 详情页模型。context：{loggedIn: Bool, privacy: "consented" | "basic"}。
public enum ProductDetailState {
    /// BR-PRICE-11：age_sec 超过 300 秒提示；正好 300 不提示。
    public static let staleAgeSec: Int64 = 300

    public static func map(_ product: [String: Any], context: [String: Any]) -> ProductDetailView {
        let key = JSON.string(JSON.object(product["cta"])?["text_key"]) ?? ""
        let unavailable = priceUnavailable(product)
        let offShelf = JSON.string(product["availability"]) == Availability.offShelf.rawValue
        let loggedIn = JSON.bool(context["loggedIn"]) == true
        return ProductDetailView(
            buttonKeyRaw: key,
            presale: JSON.bool(product["is_presale"]) == true,
            rebateUnknown: JSON.string(product["rebate_basis"]) == RebateBasis.amountUnknown.rawValue,
            degraded: false,
            rebateGone: false,
            publicMode: !loggedIn || JSON.string(context["privacy"]) == "basic",
            buyEnabled: !key.isEmpty && !offShelf && !unavailable,
            stale: stale(product),
            priceUnavailable: unavailable
        )
    }

    /// 与 DesignSystem ProductCardMapper.priceUnavailable 同一判定（两处各写一份，测试互相核对）。
    public static func priceUnavailable(_ product: [String: Any]) -> Bool {
        if JSON.string(product["availability"]) == Availability.priceUnavailable.rawValue {
            return true
        }
        if JSON.string(product["rebate_basis"]) == RebateBasis.amountUnknown.rawValue {
            return false
        }
        // 新券后价已知、券前价与券额待补齐（APP-06b 共性第 34 条）：照常可买
        if JSON.bool(product["client_price_pending"]) == true, JSON.int64(product["final_price_fen"]) != nil {
            return false
        }
        return ["price_fen", "coupon_fen", "final_price_fen"].contains { JSON.int64(product[$0]) == nil }
    }

    /// BR-PRICE-11：stale=true，或 age_sec > 300。
    public static func stale(_ product: [String: Any]) -> Bool {
        if JSON.bool(product["stale"]) == true {
            return true
        }
        return (JSON.int64(product["age_sec"]) ?? 0) > staleAgeSec
    }
}
