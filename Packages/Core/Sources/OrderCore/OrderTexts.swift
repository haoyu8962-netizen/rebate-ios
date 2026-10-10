import Foundation
import Generated

/// 订单页面取文案的接口（BR-TEXT-12：页面不写中文，只取键）。生产为 `OrderDraftTexts`（契约字典优先，草稿兜底）。
public protocol OrderTexts {
    /// 不带变量的文案；带 {变量} 的文案按 fallback（BR-TEXT-14），没有 fallback 时去掉占位；缺键为空串。
    func text(_ key: String) -> String
    /// 填 {变量}；值为空或仍有没填上的变量时用 fallback；没有 fallback 时去掉未填的占位。
    func format(_ key: String, _ vars: [String: String]) -> String
}

/// 订单与待跟单卡里契约 texts.default.json 还没有的文案键（rule-gaps G01、G14、G21：状态文案、原因文案、金额格标签、页面结构与按钮）。
/// 原文逐字取 BR-TEXT-02 映射表、BR-TEXT-05 细则表、BR-TEXT-14 表 C 与设计稿 Orders* / OrderDetail* / ProductPendingTrack；
/// 「代拟」的几条（复制失败、网络错误、PUNISH 默认说明、申诉中说明去掉提交时间）设计稿与规划都没有，提审前替换。
/// 契约里已有的键（order_list.*、order_status_group.*、order_timeline.deposit_paid / final_paid、pending_track_card.title / desc、
/// net.stale_data、perm.push.*、amount_mask.hide / show、error.*）一律读 DefaultTexts，不放这里。三端同名（Android / 鸿蒙 OrderDraftTexts）。
///
/// TODO(N-31) 整张表都是「待定稿，不得提审」：契约补键（/v1/dict 或 texts.default.json）后删除本表、改读字典。
public struct OrderDraftTexts: OrderTexts {
    public static let traceSuffixKey = "order.trace_suffix"

    public init() {}

    /// TODO(N-31) 待定稿，不得提审。键 → 草稿文字。
    public static let drafts: [String: String] = [
        // ---- 状态文案（BR-TEXT-02 映射表，G01）
        "order_status.DEPOSIT_PAID.label": "已付定金",
        "order_status.DEPOSIT_PAID.hint": "尾款付清后计算返利",
        "order_status.PAID.label": "已付款，返利待确认",
        "order_status.PAID.hint": "确认收货后随联盟月度结算入账",
        "order_status.WAITING.label": "已收货，等待联盟结算",
        // {credit_period} 已是「11 月」/「2027 年 1 月」，占位后不再加空格（A03）
        "order_status.WAITING.hint": "预计 {credit_period}结算",
        "order_status.CREDITING.label": "入账核对中",
        "order_status.CREDITING.hint": "如有疑问请联系客服",
        "order_status.RIGHTS_PENDING.label": "售后处理中，入账暂停",
        "order_status.RIGHTS_PENDING.hint": "售后结束后随联盟结算入账",
        "order_status.REVIEWING.label": "入账核对中",
        "order_status.REVIEWING.hint": "如有疑问请联系客服",
        "order_status.NO_REBATE.label": "本单无返利",
        "order_status.CREDITED.label": "已结算",
        "order_status.CREDITED_PART_CLAWED.label": "已结算（部分扣回 {z}）",
        "order_status.INVALID.label": "已失效",
        "order_status.CLAWED_BACK.label": "已扣回",
        "order_status.UNKNOWN.label": "状态更新中",
        "order_status.UNKNOWN.hint": "请稍后查看",
        // ---- 原因（BR-TEXT-05 细则表，G01；PUNISH 子原因 G04 不做）
        "order_reason.REFUND.title": "订单已退款或取消",
        "order_reason.REFUND.desc": "退款或取消后平台不再支付返利",
        "order_reason.PART_REFUND.title": "部分退款",
        "order_reason.PART_REFUND.desc": "返利按剩余金额计算",
        "order_reason.RIGHTS.title": "发起售后维权，返利取消",
        "order_reason.RIGHTS.desc": "售后成功后平台不再支付这笔返利",
        "order_reason.PUNISH.title": "订单被联盟判定违规",
        // 代拟：BR-TEXT-05 的 PUNISH 说明按 reason_sub 细分，OrderDetail 没有 reason_sub（G04），先给不带子原因的默认说明
        "order_reason.PUNISH.desc": "如有疑问可联系客服",
        "order_reason.PRICE_COMPARE.title": "比价订单",
        "order_reason.PRICE_COMPARE.desc": "联盟按比价订单规则计算，返利相应降低",
        "order_reason.PRICE_PROTECT.title": "商家价保退差",
        "order_reason.PRICE_PROTECT.desc": "返利按价保后实付金额重新计算",
        "order_reason.SETTLE_DIFF.title": "结算金额调整",
        "order_reason.SETTLE_DIFF.desc": "联盟结算金额与预估不同，已按结算金额调整",
        "order_reason.NOT_TRACKED.title": "未找到这笔订单的返利记录",
        "order_reason.NOT_TRACKED.desc": "可能不是通过本 App 链接下单，或下单前点过其他返利链接",
        "order_reason.EXPIRED_CLICK.title": "下单时链接已过期",
        "order_reason.EXPIRED_CLICK.desc": "点击链接超过 {click_valid_days} 天才下单",
        "order_reason.RELATION_INVALID.title": "淘宝授权未完成或已失效",
        "order_reason.RELATION_INVALID.desc": "重新授权后可提交找回",
        "order_reason.OTHER_TLJ.title": "订单归其他推广者",
        "order_reason.OTHER_TLJ.desc": "下单时使用了其他推广者的淘礼金",
        "order_reason.BLACKLIST.title": "订单未通过安全校验",
        "order_reason.BLACKLIST.desc": "如有疑问可提交申诉",
        "order_reason.PRESALE_UNPAID.title": "预售尾款未付",
        "order_reason.PRESALE_UNPAID.desc": "尾款未付，订单未成交",
        "order_reason.COMMISSION_ZERO.title": "返利已取消",
        "order_reason.COMMISSION_ZERO.desc": "平台将这笔订单的返利调整为 0，平台未说明原因",
        "order_reason.OTHER.title": "其他原因",
        "order_reason.OTHER.desc": "可联系客服查询",
        "order_reason.clawed_back_extra": "已从余额扣除",
        // ---- 金额格标签（G14：设计稿 Orders / OrderDetail* 原文）
        "order_amount.paid": "实付金额",
        "order_amount.est_rebate": "预估返",
        "order_amount.actual": "实返",
        "order_amount.rebate": "返利",
        "order_amount.clawback": "扣回",
        "order_amount.est_promo": "预估推广收益",
        "order_amount.promo": "推广收益",
        // ---- 订单列表（设计稿 Orders、OrdersShare、OrdersEmpty、OrdersShareEmpty、OrdersSearch*、OrdersFilter*）
        "order_list.title": "订单",
        "order_list.tab.self": "自购",
        "order_list.tab.share": "分享",
        "order_list.find_entry": "未跟单？去找回",
        "order_list.search.label": "搜索订单",
        "order_list.search.clear": "清除",
        "order_list.empty.self.title": "还没有自购订单",
        "order_list.empty.self.message": "通过凑狸领券下单后，订单会显示在这里；下单后没看到，可以点「去找回」提交",
        "order_list.empty.share.title": "还没有分享订单",
        "order_list.empty.share.message": "好友通过你分享的商品下单后，订单会显示在这里",
        "order_list.empty.action": "去首页逛逛",
        "order_list.search.found": "找到 {n} 笔订单",
        "order_list.search.none": "没有找到相关订单",
        "order_list.search.share_note": "分享订单只按商品名搜索",
        "order_list.filter.all_platforms": "全部平台",
        "order_list.filter.all_months": "全部月份",
        "order_list.filter.month_note": "按付款时间；预售单按付定金时间",
        "order_list.filter.month_item": "{year} 年 {month} 月",
        "order_list.filter.close": "关闭",
        // 读屏：筛选按钮的展开状态（iOS 没有系统的「已展开」特性，用值表达；adaptation-a11y-spec §9）
        "order_list.filter.expanded": "已展开",
        "order_list.filter.collapsed": "已收起",
        "order_list.load_more": "上拉加载更多",
        "order_list.loading": "加载中",
        "order_list.end": "没有更多了",
        "order_list.quantity": "件数 {n}",
        "order_list.order_no": "订单号 {no}",
        "order_list.copy": "复制",
        "order_list.copy_label": "复制订单号",
        // 读屏：分享单脱敏号里的「*」读作「星号」（adaptation-a11y-spec §9）
        "order_list.star_spoken": "星号",
        "order_list.image_placeholder": "商品图",
        "order_list.retry": "重试",
        // 代拟：断网、超时（没有缓存时的错误态；BR-TEXT-14 没有网络错误的键）
        "order_list.network_error": "网络不可用，请检查网络后重试",
        "order_list.load_failed": "加载失败",
        // ---- 订单详情（设计稿 OrderDetail*）
        "order_detail.title": "订单详情",
        "order_detail.back": "返回",
        "order_detail.why_no_rebate": "为什么没返利？",
        "order_detail.view_help": "查看说明",
        "order_detail.timeline": "时间线",
        // 原因说明与「已从余额扣除」之间的分隔（设计稿 OrderDetailClawedBack）
        "order_detail.desc_join": "；",
        "order_detail.appeal_pending.title": "申诉中",
        // 代拟：设计稿写「10月12日 10:30 提交，结果会通过站内信通知你」，OrderDetail 没有申诉提交时间（G08），去掉时间
        "order_detail.appeal_pending.desc": "结果会通过站内信通知你",
        "order_detail.appeal_progress": "查看申诉进度",
        "order_detail.copy.done": "已复制订单号",
        // 代拟：记 hash 失败不写剪贴板时的提示（APP-07 共性第 23 条；设计稿与规划都没有）
        "order_detail.copy.failed": "复制失败，请重试",
        // ---- 详情按钮（BR-TEXT-02 状态固有按钮、BR-TEXT-05 action）
        "order_action.withdraw": "去提现",
        "order_action.ledger": "查看流水",
        "order_action.contact_cs": "联系客服",
        "order_action.appeal": "去申诉",
        "order_action.claim": "去找回",
        "order_action.reauth": "去授权",
        // ---- 时间线（BR-TEXT-02「时间线」，G01、G16）
        "order_timeline.paid": "付款",
        "order_timeline.received": "收货",
        "order_timeline.credit_expected": "联盟结算",
        "order_timeline.credit_expected_month": "预计 {credit_period}结算",
        "order_timeline.credited": "已结算",
        "order_timeline.invalid": "失效",
        "order_timeline.clawed_back": "扣回",
        "order_timeline.part_clawed_back": "部分扣回",
        "order_timeline.not_happened": "未发生",
        // ---- 待跟单卡（ProductPendingTrack）
        "pending_track_card.close": "关闭订单同步提示",
        "pending_track_card.claim": "未跟单？去找回",
        // ---- 金额隐藏（BR-TEXT-10 细则「金额隐藏」，G21；adaptation-a11y-spec §9）
        "amount_mask.mask": "****",
        "amount_mask.hidden_spoken": "金额已隐藏",
        // ---- 追踪编号后缀（文案里没有 {trace6} 占位时追加；同 iOS 搜索的 error.trace_suffix，TODO(N-27)）
        "order.trace_suffix": "（{trace6}）",
        // ---- 平台名（contracts/enums/platform.yaml 的显示名未入契约字典）
        "platform.taobao": "淘宝",
        "platform.jd": "京东",
        "platform.pdd": "拼多多",
        "platform.meituan": "美团",
        "platform.vip": "唯品会",
        "platform.douyin": "抖音",
        "platform.eleme": "饿了么",
        "platform.kuaishou": "快手",
        "platform.suning": "苏宁",
    ]

    /// 草稿的 fallback（变量缺失时；BR-TEXT-14 缺变量回退）。
    static let draftFallbacks: [String: String] = [
        "order_status.CREDITED_PART_CLAWED.label": "已结算（部分扣回）",
        "order_reason.EXPIRED_CLICK.desc": "点击链接超过有效期才下单",
        "order_timeline.credit_expected_month": "联盟结算",
        "order_list.search.found": "找到相关订单",
    ]

    private static let placeholder = "\\{[a-z0-9_]+\\}"

    private func raw(_ key: String) -> String? {
        DefaultTexts.text(key) ?? Self.drafts[key]
    }

    private func fallback(_ key: String) -> String? {
        DefaultTexts.fallback(key) ?? Self.draftFallbacks[key]
    }

    private static func hasPlaceholder(_ text: String) -> Bool {
        text.range(of: placeholder, options: .regularExpression) != nil
    }

    private static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: placeholder, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public func text(_ key: String) -> String {
        guard let raw = raw(key) ?? fallback(key) else { return "" }
        guard Self.hasPlaceholder(raw) else { return raw }
        return fallback(key) ?? Self.strip(raw)
    }

    public func format(_ key: String, _ vars: [String: String]) -> String {
        guard var result = raw(key) else { return text(key) }
        for (name, value) in vars where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard Self.hasPlaceholder(result) else { return result }
        return fallback(key) ?? Self.strip(result)
    }

    /// 平台显示名（不认识的平台返回空串，不显示编码原文）。
    public func platformName(_ platform: String) -> String {
        text("platform." + platform)
    }
}
