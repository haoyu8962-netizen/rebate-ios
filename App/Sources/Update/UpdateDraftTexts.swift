// TODO(N-16) 待契约补键，不得提审：强更页与可关闭提示里契约 texts.default.json 还没有键的几处（标题、副标题、
// 「更新内容」），照设计稿 ForceUpdate / MainUpdatePrompt 逐字放在这一处。有键的（app_update.*）一律读 DefaultTexts。
// 契约补 app_update.title / app_update.subtitle / app_update.notes_title 等键后整文件删除（提审前 QA-07 必须替换）。
// 只允许 App 外壳引用；Feature 目录不得出现中文。
//
// 来源：design-hifi/project/ForceUpdate.dc.html、ForceUpdateUnavailable.dc.html、MainUpdatePrompt.dc.html（逐字）。

/// 强更页与可关闭提示的草稿文字（集中一处）。
enum UpdateDraftTexts {
    /// 强更页标题（「发现新版本 2.1.0」），版本号取检查结果的 latest_version。TODO(N-16) 不得提审。
    static func title(version: String?) -> String {
        guard let version, !version.isEmpty else { return "发现新版本" }
        return "发现新版本 \(version)"
    }

    /// 强更页副标题；可关闭提示没有 update_notes 时的说明（MainUpdatePrompt 标注）。TODO(N-16) 不得提审。
    static let subtitle = "当前版本过低，请更新后继续使用"

    /// 更新内容卡片标题。TODO(N-16) 不得提审。
    static let notesTitle = "更新内容"
}
