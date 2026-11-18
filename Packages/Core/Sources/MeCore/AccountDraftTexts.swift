import Foundation
import Generated
import WalletCore

/// 注销页（APP-13a-1）里契约 texts.default.json 还没有的文案键（集中草稿表，照 N-11 / N-26 / N-30–N-33 的做法；brief §0「通用」）。
/// 设计稿有原文的逐字取设计稿（DeleteAccount、DeleteAccountNegative、DeleteAccountCooling 画板），设计稿也没有的标「代拟」。契约已有的键
/// （deletion.*、pending_confirm.*、error.*、app_update.*、step_up.no_available_method 等）一律读 DefaultTexts，不放这里；钱包已有的草稿键
/// （wallet.retry、wallet.network_error、step_up.* 面板键）经 WalletDraftTexts 读，不重复建。
///
/// TODO(N-37) 整张表都是「待定稿，不得提审」：契约补键后删除本表、改读字典。
public struct AccountDraftTexts: WalletTexts, MeTexts {
    public init() {}

    /// TODO(N-37) 待定稿，不得提审。
    public static let drafts: [String: String] = [
        // 页面标题（设计稿 DeleteAccount 导航栏）
        "deletion.title": "账号注销",
        // 资金区标签（设计稿；资金术语，BR-TEXT-12）
        "deletion.withdrawable": "可提现余额",
        "deletion.estimated": "预估收益",
        "deletion.negative_label": "待抵扣",
        // 注销须知六条（设计稿 DeleteAccount 逐字；G13：不显示「查看完整《注销须知》」）
        "deletion.notice.1": "提交后有 7 天冷静期，冷静期内可以随时撤回",
        "deletion.notice.2": "冷静期内账号只能查看，不能领券购买、提现和邀请好友",
        "deletion.notice.3": "冷静期满后进入注销处理，自提交起 15 个工作日内完成",
        "deletion.notice.4": "注销后手机号、昵称、实名信息、收款账号等会被删除，账号无法恢复",
        "deletion.notice.5": "注销后用同一手机号可以重新注册，但不能再领新人奖励",
        "deletion.notice.6": "有进行中的提现时不能申请，请等提现完成",
        // 勾选句（设计稿；资金术语，BR-TEXT-12）与读屏（adaptation-a11y-spec：「…，复选框，未选中 / 已选中」）
        "deletion.waiver": "放弃未提现余额和预估收益",
        "deletion.waiver.role": "复选框",
        "deletion.waiver.on": "已选中",
        "deletion.waiver.off": "未选中",
        // 【联系客服】（设计稿 DeleteAccountNegative）
        "deletion.contact_cs": "联系客服",
        // 代拟：G10 未绑手机账号、full 会话给的入口（编排者补充 3）
        "deletion.go_bind_phone": "去绑定手机号",
        // 代拟：读取失败态（待补稿）
        "deletion.load_failed": "注销进度没有加载出来，请重试",
        "deletion.funds_failed": "账户资金没有加载出来，加载后才能申请注销",
        // 代拟：撤回已不可用（10007）；撤回结果未知（brief §2.4 原文）
        "deletion.cooling.cancel_expired": "冷静期已结束，不能再撤回注销",
        "deletion.cooling.cancel_unknown": "暂时没有收到结果，请稍后再试",
        // 代拟：冷静期 can_cancel=false（G15，待补稿）
        "deletion.cooling.cannot_cancel": "冷静期已结束，注销正在处理",
        // 代拟：二次验证面板随 action 变的标题（error.10003 的句子写的是「资金安全」）
        "step_up.title.account_deletion": "为保障账号安全，请先完成短信验证",
    ]

    /// 冷静期处理时长（timeline.processing_desc 的 {process_workdays}）：契约与接口都没有下发，取设计稿 / BR-ID-27 的 15 个工作日。
    /// TODO(N-37) 待契约给出取值来源。
    public static let processWorkdays = 15

    private let base = WalletDraftTexts()

    private static func draft(_ key: String) -> String? {
        DefaultTexts.text(key) == nil ? drafts[key] : nil
    }

    public func has(_ key: String) -> Bool {
        Self.draft(key) != nil || base.has(key)
    }

    public func text(_ key: String) -> String {
        guard let raw = Self.draft(key) else { return base.text(key) }
        return Self.strip(raw)
    }

    public func format(_ key: String, _ vars: [String: String]) -> String {
        guard var raw = Self.draft(key) else { return base.format(key, vars) }
        for (name, value) in vars where !value.isEmpty {
            raw = raw.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return Self.strip(raw)
    }

    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\\{[a-z0-9_]+\\}", with: "", options: .regularExpression)
    }
}
