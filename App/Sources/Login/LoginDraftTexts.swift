import Generated
import Login

// TODO(N-26) 待定稿，不得提审：登录页与退出登录里契约 texts.default.json 还没有的文案键（APP-05a rule-gaps TEXT-01）。
// 照设计稿 Login、LoginAgreeConfirm、LoginCode、LoginCodeBlocked、LoginCodeInvite、LoginInviteBound、LoginInviteFailed、
// LoginDeletionProcessing 逐字集中放在这一处；规划 BR-TEXT-14 已有措辞的（login.risk_blocked.desc、cs.appeal_entry、
// settings.logout.*）照规划原文。三端同名（iOS / Android / 鸿蒙 LoginDraftTexts）。
// 有键的（error.*、invite.notice_inviter、login.help_entry）一律读 DefaultTexts，不放这里。
// 整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
// 只允许 App 外壳引用；Feature 目录不得出现中文。

/// 登录相关草稿文字（集中一处）。TODO(N-26) 待定稿，不得提审。
enum LoginDraftTexts {
    /// TODO(N-26) 待定稿，不得提审。键 → 草稿文字。
    static let drafts: [String: String] = [
        // Login
        "login.brand": "凑狸",
        "login.close": "关闭",
        "login.back": "返回",
        "login.settings": "设置",
        "login.title": "手机号登录",
        "login.phone.label": "手机号",
        "login.phone.prefix": "+86",
        "login.phone.placeholder": "请输入手机号",
        "login.phone.clear": "清除手机号",
        "login.agree.prefix": "我已阅读并同意",
        "login.agree.agreement": "《用户协议》",
        "login.agree.and": "和",
        "login.agree.privacy": "《隐私政策》",
        "login.agree.suffix": "，",
        "login.agree.hint": "未注册的手机号验证后自动创建账号",
        "login.get_code": "获取验证码",
        "login.invite.entry": "有邀请码？填写邀请码（选填）",
        "login.other_methods": "其他登录方式",
        "login.apple": "通过 Apple 登录",
        // LoginAgreeConfirm
        "login.agree_confirm.title": "请阅读并同意协议",
        "login.agree_confirm.body_prefix": "登录前请阅读并同意",
        "login.agree_confirm.body_suffix": "。",
        "login.agree_confirm.cancel": "取消",
        "login.agree_confirm.ok": "同意并继续",
        // LoginCode / LoginCodeInvite
        "login.code.title": "输入验证码",
        "login.code.sent_to": "验证码已发送至 {phone}",
        "login.code.label": "验证码",
        "login.code.countdown": "{sec} 秒后可重新获取",
        "login.code.resend": "重新获取",
        // 「继续输入验证码」独立入口（APP-05a 共性 16；设计稿没有这个入口，措辞待定稿）
        "login.code.continue": "已收到验证码？继续输入",
        "login.invite.label": "邀请码（选填）",
        "login.invite.placeholder": "6 位邀请码",
        "login.invite.clear": "清除邀请码",
        // ---- APP-17c：登录页顶部待绑定码小字行（措辞照规划 BR-TEXT-14 表 C 原文；2026-10-19 起旁边不显示告知句）
        "login.pending_invite": "已识别好友邀请码 {code}",
        "login.pending_invite.remove": "移除",
        "login.submit": "登录",
        // LoginCodeBlocked（标题用 error.44001；说明句 BR-TEXT-14 表 C 已有措辞）
        "login.risk_blocked.desc": "账号没有创建，填写的手机号保留在本页，验证码需要重新获取。如有疑问，可以联系客服申诉，客服核实后会帮你登记。",
        "login.risk_blocked.ok": "知道了",
        "cs.appeal_entry": "联系客服申诉",
        // LoginDeletionProcessing（标题用 error.10007）
        "login.deletion.body": "这个账号正在注销，注销完成前不能登录。注销自提交起 15 个工作日内完成，完成后可以用同一手机号重新注册。如有疑问，可以联系客服。",
        "login.deletion.cs": "联系客服",
        "login.deletion.ok": "知道了",
        // LoginInviteBound / LoginInviteFailed（BR-INV-06 细则：42901 另有一句）
        "login.invite_bound": "登录成功，已绑定邀请人",
        "login.invite_failed.title": "邀请码未生效",
        "login.invite_failed.body": "邀请码无效，注册 7 天内可在“我的”补填",
        "login.invite_failed.rate_limited": "尝试次数过多，请明天再试",
        "login.invite_failed.ok": "知道了",
        "login.invite_failed.backfill": "去补填",
        // ---- APP-05b：第三方登录区（Login 画板「其他登录方式」）、provider 名（{provider_name}）
        "login.wechat": "微信登录",
        "login.wechat.short": "微信",
        "login.provider.wechat": "微信",
        "login.provider.apple": "Apple",
        // ---- APP-05b：LoginBindPhoneGuide 按钮（标题、正文用契约 invite.bind_phone_guide.*）
        "invite.bind_phone_guide.skip": "暂不",
        "invite.bind_phone_guide.go": "去绑定",
        // ---- APP-05b：BindPhone / BindPhoneMerge（说明条用契约 invite.bind_phone_guide.body，并号正文用契约 error.30411.mergeable）
        "bind_phone.title": "绑定手机号",
        "bind_phone.code.placeholder": "6 位验证码",
        "bind_phone.countdown": "{sec} 秒后重新获取",
        "bind_phone.submit": "绑定",
        "bind_phone.done": "手机号已绑定",
        // 倒计时结束、可以重新获取时的读屏播报（设计稿与契约都没有这句，共性第 11 条）
        "bind_phone.can_resend": "可以重新获取验证码",
        "bind_phone.merge.title": "并入原账号",
        "bind_phone.merge.into": "并入到",
        "bind_phone.merge.account": "手机号账号 {phone}",
        "bind_phone.merge.cancel": "取消",
        "bind_phone.merge.ok": "并入",
        // 锁定契约没有并号接口（TODO(N-29) MERGE-SUCCESS），确认后不发请求，提示暂不可用（与 Android / 鸿蒙同句）
        "bind_phone.merge.unavailable": "暂时无法并入原账号，请稍后再试，或退出后用手机号登录",
        // ---- APP-05b：BindPhone 待确认卡（APP-13a G07：版式照 PhoneChangePendingConfirm；首次绑定没有「当前手机号」一行）
        "bind_phone.pending.phone_label": "提交的手机号",
        "bind_phone.pending.time_label": "提交时间",
        "bind_phone.pending_hint": "结果确认前不能再次绑定手机号",
        // 设置页·退出登录（BR-TEXT-14 表 C settings.logout.*，契约快照未同步）
        "settings.logout": "退出登录",
        "settings.logout.confirm": "确定退出登录？",
        "settings.logout.confirm_ok": "退出登录",
        "settings.logout.confirm_cancel": "取消",
    ]

    /// 先取契约字典，再取草稿；缺键返回空串。
    static func text(_ key: String) -> String {
        DefaultTexts.text(key) ?? drafts[key] ?? DefaultTexts.fallback(key) ?? ""
    }

    /// 带变量：{name} 替换为值；还剩占位（如没给 trace6）时用契约 fallback 文案。
    static func format(_ key: String, _ vars: [String: String]) -> String {
        var text = DefaultTexts.text(key) ?? drafts[key] ?? ""
        for (name, value) in vars where !value.isEmpty {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        if text.contains("{"), text.contains("}") {
            return DefaultTexts.fallback(key) ?? text.replacingOccurrences(
                of: "\\{[a-z0-9_]+\\}", with: "", options: .regularExpression
            )
        }
        return text
    }
}

/// 登录页的文案来源：契约字典 → 草稿表。
struct AppLoginTexts: LoginTexts {
    func text(_ key: String) -> String {
        LoginDraftTexts.text(key)
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        LoginDraftTexts.format(key, vars)
    }
}
