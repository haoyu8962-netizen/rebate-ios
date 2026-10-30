import Foundation
import Generated

// TODO(N-30) 待定稿，不得提审：剪贴板识别（APP-07）里契约 texts.default.json 还没有的文案键（规则空白 G11，needs.md N-30）。
// 照规划原文（BR-TEXT-14、BR-INV-04）或设计稿 HomeClipboard、HomeClipboardInvite、SearchTyping、LoginCodeInvite、ShareHubInvalid 逐字
// 集中放在这一处。三端同名（iOS / Android / 鸿蒙 ClipboardDraftTexts）。有键的（clipboard.prompt、clipboard.invite_prompt、error.*）
// 一律读 DefaultTexts，不放这里。整张表都是「待定稿，不得提审」：契约补键后删除本文件、改读 DefaultTexts；提审前（QA-07）必须替换。
// iOS 的粘贴按钮是系统 UIPasteControl（文字与读屏名由系统提供），旁边的说明文字取这里的键。

/// 剪贴板草稿文字（集中一处）。TODO(N-30) 待定稿，不得提审。
enum ClipboardDraftTexts {
    /// TODO(N-30) 待定稿，不得提审。键 → 草稿文字。
    static let drafts: [String: String] = [
        // HomeClipboard / HomeClipboardInvite：提示条按钮的读屏名（商品条是系统粘贴控件，读屏名由系统给）与关闭
        "clipboard.prompt.action_label": "粘贴查返利",
        // APP-11v A6：按钮可见字【绑定】、读屏名「绑定邀请人」（HomeClipboardInvite-v3；主线裁定三端统一）
        "clipboard.invite_prompt.action": "绑定",
        "clipboard.invite_prompt.action_label": "绑定邀请人",
        "clipboard.prompt.close": "关闭",
        // 首页常驻粘贴卡的标题（即系统粘贴按钮的说明文字，BR-ID-16；Main-v3 / HomeGuest-v3，APP-11v：无副标题）
        "clipboard.paste_hint": "粘贴查返利",
        // 系统粘贴控件旁边的说明文字（BR-ID-16「粘贴查返利」；SearchTyping）
        "clipboard.paste_entry": "粘贴查返利",
        "clipboard.paste_entry.hint": "复制了商品链接？点下方按钮识别并查返利",
        // 30132 的【用商品名搜索】（BR-TEXT-14 表 A；ShareHubInvalid 的提示样式）
        "clipboard.search_by_name": "用商品名搜索",
        "clipboard.notice.close": "关闭",
        // 多卡弹层（没有专稿，按搜索卡样式列出，标题措辞待定稿）
        "clipboard.card_list.title": "识别到的商品",
        "clipboard.card_list.close": "关闭",
        // ⑤ 网络失败结果上的【重试】（HomeClipboardResults-v3 ⑤；与 Android / 鸿蒙同键同字）：用本次已提取的候选再发一次，不再读剪贴板
        "clipboard.retry": "重试",
        // 登录验证码页邀请码行【粘贴】（LoginCodeInvite）旁的读屏说明与抽不到时的轻提示（BR-INV-04「未识别到邀请码」）
        "clipboard.login_invite.paste_label": "粘贴邀请码",
        "clipboard.login_invite.not_found": "未识别到邀请码",
        // 错误正文后的追踪编号（03 §4.2；文案键没有 {trace6} 占位时补在正文后；与搜索页同一写法）
        "error.trace_suffix": "（{trace6}）",
    ]

    private static let placeholder = "\\{[a-z0-9_]+\\}"

    /// 先取契约字典，再取草稿；带 {变量} 而没有给值的用 fallback。缺键返回空串。
    static func text(_ key: String) -> String {
        format(key, [:])
    }

    /// 填 {变量}；值为空或仍有没填上的变量时用 fallback（BR-TEXT-14：缺变量回退）。
    static func format(_ key: String, _ vars: [String: String]) -> String {
        guard var result = DefaultTexts.text(key) ?? drafts[key] else {
            return DefaultTexts.fallback(key) ?? ""
        }
        for (name, value) in vars where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard result.range(of: placeholder, options: .regularExpression) != nil else { return result }
        return DefaultTexts.fallback(key)
            ?? result.replacingOccurrences(of: placeholder, with: "", options: .regularExpression)
    }

    /// 错误文案（03 §4.2、BR-TEXT-14；共性第 9 条）：键不存在或正文为空（未收录的 5xxxx 等）回落到 error.50001；有 trace_id 时统一附末
    /// 6 位——文案里有 {trace6} 占位的填进去，没有的补在正文后，不依赖文案里有占位（APP-06a 共性第 6、12 条）。
    static func error(_ key: String?, traceId: String?) -> String {
        let trace6 = traceId.map { String($0.suffix(6)) } ?? ""
        var text = format(key ?? genericKey, ["trace6": trace6])
        if text.isEmpty {
            text = format(genericKey, ["trace6": trace6])
        }
        guard !trace6.isEmpty, !text.contains(trace6) else { return text }
        return text + format("error.trace_suffix", ["trace6": trace6])
    }

    static let genericKey = "error.50001"
}
