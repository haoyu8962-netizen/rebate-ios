import Generated
import SwiftUI

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

    /// 任意令牌路径 → Color（组件任务里用于语义名之外的令牌）。
    public static func token(_ path: String) -> Color {
        guard let rgb = TokenRGB(token: path) else {
            assertionFailure("missing color token \(path)")
            return .clear
        }
        return rgb.color
    }
}
