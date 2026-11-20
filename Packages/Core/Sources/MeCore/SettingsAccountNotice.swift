import Foundation

/// 设置页账号资料区域的读取提示：`refreshFailed` = 已有快照时的刷新失败（文案前加「没有刷新」一句）。
public struct SettingsAccountNotice: Equatable, Sendable {
    public static let refreshFailedKey = "settings.refresh_failed"

    public let notice: MeNotice
    public let refreshFailed: Bool

    public init(notice: MeNotice, refreshFailed: Bool) {
        self.notice = notice
        self.refreshFailed = refreshFailed
    }

    /// 页面文案：统一错误消息（含 trace6）；刷新失败时前加「没有刷新」一句。
    public func message(_ texts: MeTexts) -> String {
        (refreshFailed ? texts.text(Self.refreshFailedKey) : "") + notice.message(texts)
    }
}
