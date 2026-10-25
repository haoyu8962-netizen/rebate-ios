import Foundation

// TODO(N-28) 待定稿，不得提审：购买流程、AuthSheet、JumpTip、AuthManage 里契约 texts.default.json 还没有的文案键
// （APP-06b rule-gaps A05–A09、I 段）。照设计稿 ProductBuyOpening、ProductBuyTimeout、ProductPriceChanged
// (+RebateGone、Cancelled)、ProductRebateGone(+Cancelled)、ProductPriceCompareNoRebate(+Cancelled)、
// ProductAuthSheet、ProductAuthDeclined、ProductAuthFailed、ProductAuthUnavailable、ProductJumpTip、
// ProductJumpNotInstalled、ProductJumpBrowser、ProductJumpSdkFailed 逐字集中放在这一处；三端同名（Android
// TradeDraftTexts）。契约有的键（buy.*、error.*、auth_manage.*、jump.taobao_sdk_unavailable、
// no_rebate.price_compare.*、share_page.copy_tpwd.done）一律读 DefaultTexts，不放这里。平台名、返回等沿用
// SearchDraftTexts。整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts。
// 只允许 App 外壳引用；Feature 目录不得出现中文。

/// 购买流程草稿文字（集中一处）。TODO(N-28) 待定稿，不得提审。
enum TradeDraftTexts {
    /// TODO(N-28) 待定稿，不得提审。键 → 草稿文字。
    static let drafts: [String: String] = [
        // 浏览器打开（ProductJumpBrowser，BR-ATTR-27 京东行「将通过浏览器打开京东」）
        "trade.browser_notice": "将通过浏览器打开{platform_name}",
        // 价格变动 / 券失效 / 返利归零（BR-PRICE-13 / 14）
        "trade.price_changed.title": "价格已变动",
        "trade.price_changed.before": "之前（{price_label}）",
        "trade.price_changed.now": "现在（{price_label}）",
        // 券失效时新价格的口径未知（coupon_gone 不等于无券，共性第 21 条）：不标口径词（I 段）
        "trade.price_changed.now_plain": "现在",
        // 原卡券额未知（改价、券失效后尚未补齐）时「之前」行不标口径词（共性第 47 条）
        "trade.price_changed.before_plain": "之前",
        "trade.price_changed.ask": "继续购买？最终价格以下单页为准",
        // 券失效没有单独的画板（BR-PRICE-14「弹券失效确认」）：标题按规则原意
        "trade.coupon_gone.title": "优惠券已失效，价格已变动",
        "trade.rebate_gone.line": "该商品当前暂无返利",
        "trade.rebate_gone.note": "继续购买不会获得返利",
        "trade.rebate_gone.title": "该商品当前暂无返利，继续购买？",
        // 只在新旧价格相同时用（共性第 45 条）；新价不同（变动未达阈值）用 body_changed，{price_now} 是「现在（券后）」或券额未补齐时的「现在」
        "trade.rebate_gone.body": "价格没有变化，{price_label} {price}。继续购买不会获得返利",
        "trade.rebate_gone.body_changed": "{price_now} {price}。继续购买不会获得返利",
        // 新旧金额相同但原卡口径未知（券额未补齐）：不写「券后 / 售价」（共性第 47 条）
        "trade.rebate_gone.body_plain": "价格没有变化，现在 {price}。继续购买不会获得返利",
        "trade.cancel": "取消",
        "trade.continue": "继续购买",
        "trade.cancelled.price": "已取消购买，价格已更新为最新",
        "trade.cancelled.price_rebate": "已取消购买，价格和返利信息已更新",
        "trade.cancelled.rebate": "已取消购买，返利信息已更新",
        // requote_failed（BR-PRICE-13「用返回链接外跳，同时提示价格以下单页为准」；没有画板）
        "trade.requote_notice": "暂时无法确认最新价格，以下单页为准",
        // 比价无返利（BR-PRICE-08）
        "trade.compare.body": "继续购买不会获得返利，最终价格以下单页为准。",
        "trade.compare.explain": "查看说明",
        "trade.buy_no_rebate": "仍去购买（无返利）",
        // AuthSheet / 关闭 / 失败 / 不可用（BR-ID-17 / 18 / 24）
        "trade.close": "关闭",
        "trade.auth.reason": "授权后，才能识别你在{platform_name}下的订单并计算返利",
        "trade.auth.privacy": "只用于识别订单，不获取你的{platform_name}昵称、头像和账号名",
        "trade.auth_declined.title": "未授权将无法获得返利",
        "trade.auth_declined.body":
            "完成{platform_name}授权后购买，才能识别这笔订单并计算返利。也可以不授权直接去{platform_name}购买，这笔订单不计返利。",
        "trade.auth_failed.body": "未授权将无法获得返利。可以重新授权，或不授权直接去{platform_name}购买（这笔订单不计返利）。",
        "trade.auth_unavailable.body": "商品信息保留在本页，稍后可以再点购买。",
        "trade.ok": "知道了",
        // JumpTip（BR-ATTR-21；文案后台可配 jump_tip.<platform>，配置形状未定、包内为空时用画板的两句，A07 同口径）
        "trade.jump_tip.title": "下单须知",
        "trade.jump_tip.line1": "在打开的商品页直接下单",
        "trade.jump_tip.line2": "不要加购后隔天再买",
        "trade.jump_tip.go": "知道了，去{platform_name}",
        // 外跳失败（BR-ATTR-27）
        "trade.sdk_failed.body": "这次没有跳转，商品信息保留在本页，稍后可以再点购买。",
        "trade.not_installed": "安装{platform_name}后下单才有返利",
        "trade.not_installed.copied": "安装{platform_name}后下单才有返利，口令已复制",
        // 淘宝未安装、口令复制步骤之后（ProductJumpNotInstalled-v2，G-D11；三端同名，登记 CT-16f）
        "trade.not_installed.copy_tpwd": "复制淘口令",
        "trade.not_installed.tpwd_copied": "已复制淘口令",
        "trade.jump_failed": "暂时无法打开{platform_name}，请稍后再试",
        // 跳转方案过了 expire_at（共性第 12 条；没有画板与文案键）
        "trade.jump_expired": "购买链接已过期，请重新点购买",
        // 联系客服（统一客服出口未接入，暂经 Router 打开帮助中心）
        "trade.contact": "联系客服",
        // 授权管理入口（「我的」与设置页的一行，A22 同口径）
        "trade.auth_manage.entry": "授权管理",
    ]
}
