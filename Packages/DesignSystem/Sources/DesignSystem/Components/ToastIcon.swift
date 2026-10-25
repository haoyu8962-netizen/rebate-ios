import SwiftUI
import UIKit

/// 轻提示左侧图标（APP-06v §2.8「图标按类型」）：缺省成功勾（复制、保存等既有用法外观不变）；信息 i、警告三角、复制、无图标。
public enum CouliToastIcon: Equatable, Sendable {
    /// 成功勾、成功色（既有缺省）。
    case success
    /// 信息 i、次文字色（取消后已更新、复核失败）。
    case info
    /// 警告三角、警告色（维护中）。
    case warning
    /// 复制、次文字色（已复制淘口令）。
    case copy
    /// 不画图标。
    case none

    var icon: CouliIcon? {
        switch self {
        case .success: .check
        case .info: .info
        case .warning: .alert
        case .copy: .copy
        case .none: nil
        }
    }

    var color: Color {
        switch self {
        case .success: CouliColor.statusSuccessText
        case .warning: CouliColor.statusWarningText
        case .info, .copy, .none: CouliColor.textSecondary
        }
    }
}

/// 状态变化的礼貌播报（APP-06v-b G-D07：下架不出轻提示，改由卡片状态变化时排队播报一次，不打断当前朗读）。
/// `observer`：调试 / 测试钩子（缺省 nil；App 的 Debug 构建用它记录播报内容，供 UI 测试读取）。
public enum CouliStatusAnnouncer {
    @MainActor public static var observer: ((String) -> Void)?

    /// 只在状态从无到有（false → true）时播报；进页时就已是 true、或 true → true 不播。
    public static func shouldAnnounce(was: Bool, now: Bool) -> Bool {
        !was && now
    }

    /// 排队播报（与轻提示同一礼貌规则）。
    @MainActor public static func polite(_ text: String) {
        guard !text.isEmpty else { return }
        observer?(text)
        ToastAnnouncement.post(text)
    }
}
