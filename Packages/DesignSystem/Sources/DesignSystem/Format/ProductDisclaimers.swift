import Foundation

/// 列表页底口径说明的键（BR-PRICE-03、09、17；APP-06a 共性 13、25）。搜索结果与首页商品卡共用同一条合并规则（APP-11 P2）：
/// - 卡片 disclaimer_keys 去重、按出现顺序；
/// - 有券、无券混排时价格句只放 price_basis.general（BR-PRICE-03 细则「无券商品与混排列表的口径说明」）；
/// - 返利句不能丢：有普通返利卡（normal）显示返利金额时一定带 rebate_estimate；纯比价区间卡（price_compare_risk）只用服务端
///   下发的 rebate_compare，不追加 rebate_estimate（BR-PRICE-17）；
/// - 价格口径句在前，其余按出现顺序在后（设计稿 Search / Main 页底：价格句 → 以结算为准 → 返利说明）。
public enum ProductDisclaimers {
    public static let priceBasis = "price_basis"
    public static let priceBasisGeneral = "price_basis.general"
    public static let rebateEstimate = "rebate_estimate"

    public static func footerKeys(_ items: [[String: Any]]) -> [String] {
        var keys: [String] = []
        for item in items {
            let own = (item["disclaimer_keys"] as? [Any])?.compactMap { $0 as? String } ?? []
            for key in own where !keys.contains(key) {
                keys.append(key)
            }
        }
        if keys.contains(priceBasis), keys.contains(priceBasisGeneral) {
            keys.removeAll { $0 == priceBasis }
        }
        if !keys.contains(rebateEstimate), items.contains(where: showsRebateAmount) {
            keys.append(rebateEstimate)
        }
        let price = keys.filter { $0.hasPrefix(priceBasis) }
        return price + keys.filter { !$0.hasPrefix(priceBasis) }
    }

    private static func showsRebateAmount(_ item: [String: Any]) -> Bool {
        guard item["rebate_basis"] as? String == "normal", ProductCardMapper.priceUnavailable(item) == false else {
            return false
        }
        return ((item["rebate_max_fen"] as? NSNumber)?.int64Value ?? 0) > 0
    }
}
