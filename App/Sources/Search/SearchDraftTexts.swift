import Foundation
import Generated
import ProductSearch

// TODO(N-27) 待定稿，不得提审：搜索页与商品详情页里契约 texts.default.json 还没有的文案键（APP-06a rule-gaps：
// btn.buy*、口径说明句、普通搜索空态键、平台名、排序名等未入契约）。照设计稿 Search、SearchTyping、SearchEmpty、
// SearchFilterPrice、SearchDisclaimerNote、Product、A11yHitSearch、A11yFocusProduct 逐字集中放在这一处；排序名照 BR-PRICE-18，
// 口径说明句照 BR-PRICE-17 默认文案（与 DS-01 组件目录同一句）。三端同名（iOS / Android / 鸿蒙 SearchDraftTexts）。
// 有键的（error.*、external_page.retry）一律读 DefaultTexts，不放这里。
// 整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
// 只允许 App 外壳引用；Feature 目录不得出现中文。

/// 搜索 / 详情草稿文字（集中一处）。TODO(N-27) 待定稿，不得提审。
enum SearchDraftTexts {
    /// TODO(N-27) 待定稿，不得提审。键 → 草稿文字。
    static let drafts: [String: String] = [
        // 平台名（contracts/enums/platform 的显示名未入契约字典）
        "platform.taobao": "淘宝",
        "platform.jd": "京东",
        "platform.pdd": "拼多多",
        "platform.meituan": "美团",
        "platform.vip": "唯品会",
        "platform.douyin": "抖音",
        "platform.eleme": "饿了么",
        "platform.kuaishou": "快手",
        "platform.suning": "苏宁",
        // 购买按钮动词（ProductCta.text_key，BR-TEXT-12；契约字典缺键）
        "btn.buy": "去购买",
        "btn.buy.coupon": "领券购买",
        "btn.buy.no_rebate": "去购买（无返利）",
        // 口径说明（BR-PRICE-03 / 17 默认文案；disclaimer_keys）
        "price_basis": "券后价按单件计算，不含运费及会员价等优惠，以下单页为准",
        "price_basis.general": "价格按单件计算，不含运费及会员价等优惠，以下单页为准",
        "rebate_estimate": "预估返利以平台结算为准，未结算或订单失效时不返",
        "rebate_compare": "以结算为准",
        // 卡片
        "card.disclaimer_button": "价格与返利说明",
        "card.disclaimer_title": "价格与返利说明",
        "card.disclaimer_close": "知道了",
        // 价格不可用（BR-PRICE-01、AC-S1-09）与按钮「稍后再试」（BR-TEXT-14 正文）
        "card.price_unavailable": "暂时查不到该商品价格",
        "card.retry_later": "稍后再试",
        // 错误正文后的追踪编号（03 §4.2；文案键没有 {trace6} 占位时补在正文后，共性 12）
        "error.trace_suffix": "（{trace6}）",
        // 详情页入账说明（BR-TEXT-04、F-PROD-05；设计稿 Product 口径说明框第二行，共性 15）
        "product.settle_note": "确认收货后随联盟月度结算入账",
        // 取价处的降级提示（BR-PRICE-11）
        "card.price_stale": "价格可能已变化，以下单页为准",
        // Search / SearchTyping
        "search.back": "返回",
        "search.placeholder": "搜索商品",
        "search.clear": "清除",
        "search.submit": "搜索",
        "search.tabs": "平台",
        "search.history.title": "搜索历史",
        "search.history.clear": "清空",
        "search.sort.relevance": "综合",
        "search.sort.sales_desc": "销量",
        "search.sort.final_price_asc": "券后价从低到高",
        "search.sort.rebate_desc": "返利从高到低",
        // SearchFilterPrice
        "search.filter.coupon": "只看有券",
        "search.filter.price": "价格区间",
        "search.filter.price_range": "券后 {min}–{max}",
        "search.filter.price_min_only": "券后 {min} 以上",
        "search.filter.price_max_only": "券后 {max} 以内",
        "search.filter.sheet.min": "最低价",
        "search.filter.sheet.max": "最高价",
        "search.filter.sheet.note": "按券后价筛选，单位元",
        "search.filter.sheet.reset": "重置",
        "search.filter.sheet.confirm": "确定",
        "search.filter.sheet.close": "关闭",
        "search.filter.sheet.invalid": "请输入 0.01–100000 元，最低价不能高于最高价",
        // SearchEmpty
        "search.empty.title": "没有找到符合条件的商品",
        "search.empty.message": "换个关键词，或放宽价格区间再试试",
        "search.fallback.title": "看看{platform_name}的其他商品",
        "search.fallback.note": "{platform_name}推荐商品，不受当前关键词和价格区间限制",
        // 没有可搜索的平台（BR-PROD-10；设计稿无此画板）
        "search.unavailable.title": "暂时没有可以搜索的平台",
        // 分页（设计稿无文字，按 GUIDE §3 列表底部写法）
        "search.load_more": "加载更多",
        "search.loading": "加载中",
        "search.end": "没有更多了",
        // 缓存降级（BR-PROD-07 降级表「结果顶部显示」）
        "search.stale_notice": "价格可能已变化，下单前以平台为准",
        // Product / A11yFocusProduct
        "product.title": "商品详情",
        "product.back": "返回",
        "product.ask_ai": "问问 AI",
        "product.image": "商品图片，{title}",
        "product.research": "重新搜索",
        // 购买意图（只在 Debug / Staging 冒烟时提示；TODO(APP-06b) 换成 open 流程）
        "product.buy_intent.debug": "已发出购买意图（APP-06b 接 open 流程）",
    ]
}

/// 文案来源：契约字典 → 草稿表 → 契约 fallback；缺键返回空串。
struct AppSearchTexts: SearchTexts {
    func text(_ key: String) -> String {
        DefaultTexts.text(key) ?? SearchDraftTexts.drafts[key] ?? TradeDraftTexts.drafts[key] ?? DefaultTexts
            .fallback(key) ?? ""
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        var result = DefaultTexts.text(key) ?? SearchDraftTexts.drafts[key] ?? TradeDraftTexts.drafts[key] ?? ""
        for (name, value) in vars where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard result.range(of: "\\{[a-z0-9_]+\\}", options: .regularExpression) != nil else {
            return result
        }
        return DefaultTexts.fallback(key)
            ?? result.replacingOccurrences(of: "\\{[a-z0-9_]+\\}", with: "", options: .regularExpression)
    }
}
