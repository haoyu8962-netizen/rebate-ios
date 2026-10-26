import Generated
import SwiftUI
import UIKit

/// "#RRGGBB" 令牌的 sRGB 分量（0…1）。
public struct TokenRGB: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return nil
        }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// 取 `DesignTokens.colors` 里的令牌（点分路径，如 "brand.primary"）。
    public init?(token path: String) {
        guard let hex = DesignTokens.colors[path] else {
            return nil
        }
        self.init(hex: hex)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

/// 语义颜色。名字 = 令牌路径的 lowerCamel（brand.primary → brandPrimary），三端对齐。
public enum CouliColor {
    public static let brandPrimary = token("brand.primary")
    public static let brandEmphasis = token("brand.emphasis")
    public static let brandSecondary = token("brand.secondary")
    public static let brandSubtle = token("brand.subtle")

    public static let backgroundCanvas = token("background.canvas")
    public static let backgroundSurface = token("background.surface")
    public static let backgroundMuted = token("background.muted")
    public static let backgroundPlaceholder = token("background.placeholder")

    public static let textPrimary = token("text.primary")
    public static let textSecondary = token("text.secondary")
    public static let textInverse = token("text.inverse")
    public static let textLink = token("text.link")

    public static let priceText = token("price.text")
    public static let rebateText = token("rebate.text")
    public static let rebateBackground = token("rebate.background")

    public static let statusSuccessText = token("status.success.text")
    public static let statusWarningText = token("status.warning.text")
    public static let statusErrorText = token("status.error.text")
    /// 已结算松叶绿底（APP-08v 列表状态胶囊）。锁定令牌已有 `status.success.background`（浅 / 深），DS-02 的语义名表还没收这个名字：
    /// 按 DS-02 做法在组件库以常量补上。TODO(DS-02-iOS)：语义名表补齐后并入 `usedPaths` 与三端对齐清单。
    public static let statusSuccessBackground = token("status.success.background")
    /// 警告浅底（APP-08v 断网提示条）。同上，TODO(DS-02-iOS)。
    public static let statusWarningBackground = token("status.warning.background")

    public static let borderSubtle = token("border.subtle")
    public static let borderControl = token("border.control")
    public static let focusRing = token("focus.ring")

    /// 全部语义名用到的令牌路径（测试核对它们都存在）。
    static let usedPaths = [
        "brand.primary", "brand.emphasis", "brand.secondary", "brand.subtle",
        "background.canvas", "background.surface", "background.muted", "background.placeholder",
        "text.primary", "text.secondary", "text.inverse", "text.link",
        "price.text", "rebate.text", "rebate.background",
        "status.success.text", "status.warning.text", "status.error.text",
        "border.subtle", "border.control", "focus.ring",
    ]

    /// 任意令牌路径 → Color（组件任务里用于语义名之外的令牌）。有深色取值的令牌返回随浅 / 深外观切换的颜色（UIKit 特征与 SwiftUI
    /// colorScheme 同一来源）；浅色取值仍是锁定快照里的令牌。
    public static func token(_ path: String) -> Color {
        guard let rgb = TokenRGB(token: path) else {
            assertionFailure("missing color token \(path)")
            return .clear
        }
        guard let dark = CouliDarkTokens.rgb(path) else {
            return rgb.color
        }
        let light = rgb.uiColor
        let night = dark.uiColor
        return Color(UIColor { $0.userInterfaceStyle == .dark ? night : light })
    }
}

/// 颜色令牌的深色取值（APP-11v；00 D35 三端深色）。
///
/// 本仓库锁定的令牌快照（contract.lock → couli 18ad5b4，design-tokens v0.3.0）还没有 `dark`；唯一源 couli
/// `design/tokens/design-tokens.json`
/// v0.4.0 已有浅 / 深两套。按任务书「缺令牌在组件库以常量补并登记」，这里逐条照 v0.4.0 的 `dark` 抄入（路径与唯一源一致）；
/// TODO(DS-02-iOS)：contract.lock 升到含 v0.4.0 的提交后改由生成代码提供并删除本表。
/// 应用级仍按 Info.plist 浅色外观（整 App 跟随系统深色由 DS-02-iOS 统一开），深色只在外观被显式设为深色时生效。
enum CouliDarkTokens {
    static let hex: [String: String] = [
        "brand.primary": "#C44820", "brand.emphasis": "#F0956B", "brand.secondary": "#6CC49F",
        "brand.subtle": "#3A2219", "background.canvas": "#171513", "background.surface": "#24211E",
        "background.muted": "#2F2B27", "background.placeholder": "#36312C", "text.primary": "#F2EEE6",
        "text.secondary": "#B5ACA2", "text.inverse": "#FFFFFF", "text.link": "#F0956B", "price.text": "#F2EEE6",
        "rebate.text": "#F29A6E", "rebate.background": "#3A2219", "status.success.text": "#6CC49F",
        "status.warning.text": "#E3B65C", "status.error.text": "#F28DA4", "border.subtle": "#3A3530",
        "border.control": "#8C8278", "focus.ring": "#5DBB97", "source.text": "#B5ACA2",
        "source.background": "#24211E", "source.border": "#3A3530", "rebate.solid.background": "#C44820",
        "rebate.solid.text": "#FFFFFF", "status.pending.text": "#B5ACA2", "status.pending.background": "#2F2B27",
        "status.success.background": "#16302A", "status.warning.background": "#33290F",
        "status.error.background": "#3B1A22", "border.active": "#F2EEE6",
        "button.primary.default.background": "#C44820", "button.primary.default.text": "#FFFFFF",
        "button.primary.pressed.background": "#A83B1F", "button.primary.pressed.text": "#FFFFFF",
        "button.primary.disabled.background": "#36312C", "button.primary.disabled.text": "#A39A90",
        "button.inverse.background": "#FFFFFF", "button.inverse.text": "#A83B1F", "control.checked": "#C44820",
        "badge.background": "#C44820",
    ]

    static func rgb(_ path: String) -> TokenRGB? {
        hex[path].flatMap { TokenRGB(hex: $0) }
    }
}
