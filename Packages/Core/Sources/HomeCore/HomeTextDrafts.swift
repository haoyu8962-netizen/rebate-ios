import Foundation

/// TODO(N-35): 集中草稿表；通用图名、公告关闭、错误页文案代拟，正式契约补齐后删除草稿项。
public enum HomeTextDrafts {
    public static let values = [
        "platform.taobao": "淘宝", "platform.jd": "京东", "platform.pdd": "拼多多",
        "card.disclaimer_button": "查看口径说明", "card.price_unavailable": "暂时查不到该商品价格",
        "card.retry_later": "稍后再试",
        "home.image.entry": "活动图片", "home.notice.close": "关闭公告", "home.popup.name": "首页弹窗",
        "home.popup.close": "关闭", "home.more": "更多", "home.retry": "重试", "home.load_failed": "加载失败",
        "home.loading": "正在加载", "home.finished": "已经到底了", "home.popup.image": "活动图片",
        // APP-11v（G-V09 / BR-TEXT-14 表 C，CT-16f 待补键）：首页搜索入口占位、【问 AI】、游客价值卡
        "search.placeholder": "搜商品名，或粘贴商品链接", "home.search.ask_ai": "问 AI",
        "home.guest_value.desc": "下单前先在凑狸查返利", "home.guest_value.login": "登录领返利",
    ]
}
